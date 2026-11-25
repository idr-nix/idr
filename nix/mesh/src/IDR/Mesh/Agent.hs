{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- The unprivileged host agent. It collects the host's transport addresses,
-- registers every up workload, discovers its peers, probes their health and
-- retires removed workloads. It holds the etcd credentials, and asks netd for
-- the privileged work.
module IDR.Mesh.Agent (Config (..), run) where

import Control.Concurrent.STM (TVar, check, modifyTVar', orElse, readTVar, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad (forM_, forever, unless, void, when)
import Data.ByteString.Char8 qualified as BS
import Data.Either (lefts)
import Data.IP (IP)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Concurrent.Async
  ( Async,
    async,
    cancel,
    concurrently,
    mapConcurrently_,
    poll,
    withAsync,
  )
import Effectful.Concurrent.STM (atomically, newTVarIO, readTVarIO)
import Effectful.Exception (bracket, trySync)
import Effectful.Reader.Static (Reader, ask, asks, runReader)
import IDR.Mesh.Addresses qualified as Addresses
import IDR.Mesh.Common
  ( atomicWrite,
    decodeJson,
    encodeState,
    listIfPresent,
    optionalFile,
    readSaved,
    removeIfExists,
  )
import IDR.Mesh.Converge (Scope (..), Shared (..), converge, snapshotDirectory)
import IDR.Mesh.Effects
import IDR.Mesh.Identity (ServiceId)
import IDR.Mesh.Instance qualified as Instance
import IDR.Mesh.Inventory qualified as Inventory
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.Probe (probePeers, savedUnhealthy)
import IDR.Mesh.SocketActivation (requireSocket, withActivatedSockets)
import Network.Socket
  ( Family (AF_ROUTE),
    Socket,
    SocketType (Raw),
    setNonBlockIfNeeded,
    withFdSocket,
  )
import Network.Socket.ByteString (recv)
import System.Directory (createDirectory, removePathForcibly)
import System.FilePath (dropExtension, takeExtension, (</>))
import System.INotify (EventVariety (Delete, MoveIn), addWatch, initINotify, killINotify)
import System.Posix.Signals (Handler (Catch), installHandler, sigHUP)
import System.Timeout (timeout)

-- The health port, the file that lists the etcd clusters, the directory of
-- their passwords, and the addresses to advertise instead of discovered ones.
data Config = Config
  { healthPort :: Int,
    clustersFile :: FilePath,
    credentials :: FilePath,
    explicitAddresses :: [IP]
  }

data Signals = Signals
  { -- Bumped by every event that can change which workloads should run.
    changes :: TVar Int,
    -- Set when a retirement pass is due.
    retiring :: TVar Bool
  }

type Agent es =
  ( Reader Instance.Registrar :> es,
    Reader Shared :> es,
    Reader Signals :> es,
    Locks :> es,
    Log :> es,
    Concurrent :> es,
    IOE :> es
  )

run :: Config -> IO ()
run config = withActivatedSockets $ \case
  [netlink] -> do
    requireSocket [AF_ROUTE] Raw netlink
    registrar <- Instance.Registrar (healthPort config) <$> Instance.readClusters (clustersFile config) (credentials config)
    signals <- Signals <$> STM.newTVarIO 0 <*> STM.newTVarIO True
    -- systemd reloads the agent when the inventory changes.
    void $ installHandler sigHUP (Catch (wake signals)) Nothing
    -- Registrations of the previous run end with it.
    removePathForcibly Instance.registeredDirectory
    createDirectory Instance.registeredDirectory
    shared <-
      Shared
        <$> STM.newTVarIO Nothing
        <*> STM.newTVarIO 0
        <*> (savedUnhealthy >>= STM.newTVarIO)
        <*> STM.newTVarIO Map.empty
    let effects =
          runEff
            . runConcurrent
            . runLog
            . runLocks
            . runReader registrar
            . runReader shared
            . runReader signals
    effects $
      mapConcurrently_
        id
        [ collect netlink (explicitAddresses config),
          supervise,
          retireLoop,
          liftIO (probePeers (targets shared) (unhealthy shared))
        ]
  _ -> fail "idr-mesh agent requires exactly one netlink socket"

wake :: Signals -> IO ()
wake signals = STM.atomically (modifyTVar' (changes signals) (+ 1))

-- Host addresses -------------------------------------------------------------

-- Checks observe each completed collection through this counter.
collectionsFile :: FilePath
collectionsFile = "/run/idr-mesh-addresses/collections"

-- See `encodeState`.
collectionsVersion :: Int
collectionsVersion = 1

-- Collects after host network notifications. Each message only marks the host
-- state for another collection, so an overrun that loses messages is covered
-- as well.
collect :: (Agent es) => Socket -> [IP] -> Eff es a
collect netlink explicit = do
  -- A snapshot that no longer parses only means the first collection counts as
  -- a change.
  saved <- liftIO (readSaved Addresses.addressesVersion Addresses.addressesFile)
  count <- fromMaybe 0 <$> liftIO (readSaved collectionsVersion collectionsFile)
  -- Receive through the IO manager, which needs a non-blocking descriptor.
  liftIO (withFdSocket netlink setNonBlockIfNeeded)
  pending <- newTVarIO True
  withAsync (receive pending) $ \_ -> loop pending saved (count :: Integer)
  where
    receive pending = forever $ do
      received <- trySync (liftIO (recv netlink 65536))
      atomically (writeTVar pending True)
      -- A failed receive, such as an overrun, still marks the host state. A
      -- persistent failure must not collect in a loop.
      either (const (threadDelay 5000000)) (const (pure ())) received
    loop pending previous count = do
      atomically (readTVar pending >>= check >> writeTVar pending False)
      outcome <- trySync (collectOnce explicit previous)
      case outcome of
        Right snapshot -> do
          let counter = encodeState collectionsVersion (count + 1)
          counted <- trySync (liftIO (atomicWrite collectionsFile counter))
          either (logFailure "Could not count the collection") pure counted
          loop pending (Just snapshot) (count + 1)
        Left err -> do
          logFailure "Could not collect host addresses" err
          threadDelay 1000000
          atomically (writeTVar pending True)
          loop pending previous count

-- Writes a changed snapshot, publishes the advertised addresses, and makes
-- every workload send its desired state again when local transport changed.
collectOnce ::
  (Agent es) =>
  [IP] ->
  Maybe Addresses.HostAddresses ->
  Eff es Addresses.HostAddresses
collectOnce explicit previous = do
  snapshot <- liftIO (Addresses.collect explicit)
  unless (previous == Just snapshot) $
    liftIO (atomicWrite Addresses.addressesFile (encodeState Addresses.addressesVersion snapshot))
  shared <- ask
  atomically $ do
    writeTVar (addresses shared) (Just (Addresses.advertised snapshot))
    when (Addresses.transportChanged previous snapshot) $ modifyTVar' (transport shared) (+ 1)
  pure snapshot

-- Workloads ------------------------------------------------------------------

-- A thread per workload: what it follows, how to feed it, and the thread.
data Worker k a = Worker k a (Async ())

type Workers k a = Map String (Worker k a)

-- One registration and one convergence per up workload in the inventory. Both
-- wait for the first address sample. Reconcile when netd changes a workload's
-- status, when the inventory changes, when the host's public addresses change,
-- and every five minutes in case an event was missed.
supervise :: (Agent es) => Eff es a
supervise = bracket (liftIO initINotify) (liftIO . killINotify) $ \inotify -> do
  signals <- ask
  -- netd replaces status files by rename and deletes them on Down. A queue
  -- overflow also arrives as an event.
  let statuses = BS.pack Netd.statusDirectory
  void . liftIO $ addWatch inotify [MoveIn, Delete] statuses (const (wake signals))
  loop (Map.empty, Map.empty) Nothing
  where
    loop running seen = do
      advertised <- asks addresses >>= readTVarIO
      before <- asks changes >>= readTVarIO
      outcome <- trySync (reconcileWorkloads advertised running seen)
      next <- case outcome of
        Right next -> pure next
        Left err -> (running, seen) <$ logFailure "Could not reconcile mesh workloads" err
      waitForChange advertised before
      uncurry loop next

-- The registration and convergence workers of every wanted workload.
type Running =
  ( Workers Instance.Registration (TVar Instance.Published),
    Workers Scope (TVar (Maybe Integer))
  )

-- What retirement depends on: the inventory and which workloads are up.
type Observed = (Maybe BS.ByteString, Set.Set String)

-- Matches the workers to the inventory and the up workloads, and schedules a
-- retirement pass when either changed.
reconcileWorkloads ::
  (Agent es) =>
  Maybe [Text] ->
  Running ->
  Maybe Observed ->
  Eff es (Running, Maybe Observed)
reconcileWorkloads advertised (registrations, controllers) seen = do
  -- The inventory is a symlink into the current system generation.
  inventory <- liftIO (optionalFile (BS.readFile Inventory.inventoryFile))
  let services = fmap Inventory.services . decodeJson Inventory.inventoryFile
  selected <- liftIO (maybe (pure Map.empty) services inventory)
  up <- liftIO Netd.upWorkloads
  let workloads = maybe Map.empty (const (wanted selected up)) advertised
  registrations' <-
    reconcile registrations (registrationOf advertised <$> workloads) (start Instance.register) feed
  controllers' <- reconcile controllers (scopeOf <$> workloads) (start converge) feed
  -- Without an inventory every snapshot stays. The workers already run, so a
  -- failure here must not undo this pass.
  forM_ inventory $ \_ -> do
    swept <- trySync (liftIO (removeStaleSnapshots selected))
    either (logFailure "Could not remove retained peer snapshots") pure swept
  -- Retire after a removed or stopped registration has ended.
  let observed = (inventory, Set.fromList (map (NS.serviceName . fst) up))
  when (seen /= Just observed) $ asks retiring >>= \due -> atomically (writeTVar due True)
  pure ((registrations', controllers'), Just observed)
  where
    -- A worker follows its value through a variable, so a changed value
    -- updates it in place.
    start work ns k value = do
      current <- newTVarIO value
      pure (current, work ns k current)
    feed current value =
      atomically (readTVar current >>= \old -> when (old /= value) (writeTVar current value))

-- A workload that left the inventory needs no retained snapshot.
removeStaleSnapshots :: Map String a -> IO ()
removeStaleSnapshots selected = do
  cached <- listIfPresent snapshotDirectory
  let snapshot file = takeExtension file == ".json"
      stale = [f | f <- cached, snapshot f, Map.notMember (dropExtension f) selected]
  mapM_ (removeIfExists . (snapshotDirectory </>)) stale

-- Waits until the advertised addresses or the change counter differ from what
-- the last pass saw, or for five minutes.
waitForChange :: (Agent es) => Maybe [Text] -> Int -> Eff es ()
waitForChange advertised before = do
  current <- asks addresses
  counter <- asks changes
  let changed =
        (readTVar current >>= check . (/= advertised))
          `orElse` (readTVar counter >>= check . (/= before))
  liftIO (void (timeout 300000000 (STM.atomically changed)))

-- The up workloads whose service is in the inventory.
wanted ::
  Map String Inventory.Service ->
  [(NS.Workload, Netd.Status)] ->
  Map String (NS.Workload, Inventory.Service, Netd.Status)
wanted selected up =
  Map.fromList
    [ (name, (ns, service, status))
    | (ns, status) <- up,
      let name = NS.serviceName ns,
      Just service <- [Map.lookup name selected]
    ]

registrationOf ::
  Maybe [Text] ->
  (NS.Workload, Inventory.Service, Netd.Status) ->
  (NS.Workload, Instance.Registration, Instance.Published)
registrationOf advertised (ns, service, status) =
  ( ns,
    Instance.Registration (Inventory.ipv6Prefix service) (declarations service) (Netd.publicKey status),
    Instance.Published (Netd.port status) grants (fromMaybe [] advertised)
  )
  where
    -- netd's status can trail a declaration change, so a revoked grant is
    -- never published again.
    grants = Map.restrictKeys (Netd.adverts status) (snd (declarations service))

scopeOf ::
  (NS.Workload, Inventory.Service, Netd.Status) ->
  (NS.Workload, Scope, Maybe Integer)
scopeOf (ns, service, status) =
  let (own, peers) = declarations service
   in (ns, Scope (Inventory.ipv6Prefix service) own (Set.toList peers) (Inventory.maxInstances service) (Netd.publicKey status), Netd.switchAt status)

-- The service's ID and its declared peer services.
declarations :: Inventory.Service -> (ServiceId, Set.Set ServiceId)
declarations service = (Inventory.id service, Inventory.peers service)

-- Keeps each live worker whose key still matches and feeds it the current
-- value. Cancels the rest, then starts what is missing, which also restarts a
-- worker that ended.
reconcile ::
  (Agent es, Eq k) =>
  Workers k a ->
  Map String (NS.Workload, k, v) ->
  (NS.Workload -> k -> v -> Eff es (a, Eff es ())) ->
  (a -> v -> Eff es ()) ->
  Eff es (Workers k a)
reconcile running desired start feed = do
  live <- traverse (\w@(Worker _ _ thread) -> (w,) <$> poll thread) running
  let current name (Worker k _ _, ended) =
        isNothing ended && fmap (\(_, k', _) -> k') (Map.lookup name desired) == Just k
      (kept, stopped) = Map.partitionWithKey current live
  mapM_ (\(Worker _ _ thread, _) -> cancel thread) stopped
  forM_ (Map.intersectionWith (,) kept desired) $ \((Worker _ a _, _), (_, _, v)) -> feed a v
  started <- flip traverse (Map.difference desired kept) $ \(ns, k, v) -> do
    (a, work) <- start ns k v
    Worker k a <$> async (supervised (NS.serviceName ns) work)
  pure (Map.union (fmap fst kept) started)

-- A worker that failed waits five seconds before it is started again.
-- Cancellation ends it at once.
supervised :: (Agent es) => String -> Eff es () -> Eff es ()
supervised name work = do
  result <- trySync work
  either (\err -> logFailure name err >> threadDelay 5000000) pure result
  signals <- ask
  liftIO (wake signals)

-- Retirement -----------------------------------------------------------------

-- Retires removed registrations and prunes their key stores whenever the
-- inventory or the set of up workloads changes, retrying while it fails.
retireLoop :: (Agent es) => Eff es a
retireLoop = forever $ do
  due <- asks retiring
  atomically (readTVar due >>= check >> writeTVar due False)
  -- Pruning is local, so it does not wait for etcd.
  (retired, pruned) <-
    concurrently (trySync Instance.retire) (trySync (liftIO (Netd.request Netd.Prune)))
  let results = [retired, pruned]
  unless (null (lefts results)) $ do
    mapM_ (logFailure "Could not retire mesh instances") (lefts results)
    threadDelay 5000000
    atomically (writeTVar due True)
