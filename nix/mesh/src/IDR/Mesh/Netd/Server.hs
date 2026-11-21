{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- The privileged side of the mesh. It is the only writer of workload
-- namespaces, WireGuard links, ports and PSK key stores, and it serializes all
-- work on one workload. systemd starts it on demand through its socket, and it
-- exits once idle or stopped. It never tears anything down on exit, so a
-- restart is free.
module IDR.Mesh.Netd.Server (Config (..), serve) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, check, modifyTVar', orElse, readTVar, registerDelay, stateTVar)
import Control.Concurrent.STM qualified as STM
import Control.Exception qualified as E
import Control.Monad (forM_, unless, void)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful
import Effectful.Concurrent (Concurrent, forkFinally, runConcurrent, threadDelay)
import Effectful.Concurrent.STM (atomically, readTVarIO)
import Effectful.Exception (finally, trySync)
import Effectful.Reader.Static (Reader, asks, runReader)
import GHC.Conc (threadWaitReadSTM)
import GHC.Generics (Generic)
import IDR.Mesh.Apply qualified as Apply
import IDR.Mesh.Common
  ( atomicWritePrivate,
    atomicWriteWithMode,
    describe,
    durableWrite,
    encodeState,
    listIfPresent,
    optionalFile,
    readJson,
    readSaved,
    readState,
    removeIfExists,
  )
import IDR.Mesh.Desired qualified as D
import IDR.Mesh.Dns qualified as Dns
import IDR.Mesh.Effects
import IDR.Mesh.Identity (InstanceId, MeshPrefix, ServiceId)
import IDR.Mesh.Inventory qualified as Inventory
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd
import IDR.Mesh.Netns qualified as Netns
import IDR.Mesh.PSK qualified as PSK
import IDR.Mesh.PSK.Keys (keys)
import IDR.Mesh.PeerData (Settings (settingsId))
import IDR.Mesh.SocketActivation (requireSocket, withActivatedSockets)
import Network.Socket
  ( Family (AF_UNIX),
    Socket,
    SocketType (Stream),
    accept,
    close,
    getPeerCredential,
    withFdSocket,
  )
import Network.Socket.ByteString (sendAll)
import System.Directory (createDirectoryIfMissing, doesFileExist, removePathForcibly)
import System.FilePath (dropExtension, takeExtension, (</>))
import System.Posix.Files (setFileMode)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)
import System.Timeout (timeout)

-- The mesh prefix and the inclusive WireGuard port range.
data Config = Config {prefix :: MeshPrefix, firstPort, lastPort :: Int}

data Env = Env
  { config :: Config,
    -- Port allocation runs one workload at a time.
    ports :: MVar (),
    -- Open connections.
    active :: TVar Int,
    -- The newest connection that sent each workload a desired state.
    newest :: TVar (Map String Integer),
    -- Each workload's key store contents that are not written yet, by path.
    pending :: TVar (Map String (Map FilePath ByteString))
  }

type Server es = (Reader Env :> es, Locks :> es, Log :> es, Concurrent :> es, IOE :> es)

serve :: Config -> IO ()
serve settings = withActivatedSockets $ \case
  [listener] -> do
    requireSocket [AF_UNIX] Stream listener
    stopped <- STM.newTVarIO False
    _ <- installHandler sigTERM (Catch (STM.atomically (STM.writeTVar stopped True))) Nothing
    env <- Env settings <$> newMVar () <*> STM.newTVarIO 0 <*> STM.newTVarIO Map.empty <*> STM.newTVarIO Map.empty
    runEff . runConcurrent . runLog . runLocks . runReader env $ do
      republishUnreadable
      acceptUntilIdle stopped listener 0
  _ -> fail "idr-mesh netd requires exactly one activated socket"

-- A status this release cannot read, for example one an older or newer
-- release wrote before a switch, is published again from the applied state.
-- Until then the agent neither registers nor retires that workload. The DNS
-- zone stays as it is until the agent's next desired state.
republishUnreadable :: (Server es) => Eff es ()
republishUnreadable = do
  files <- liftIO (listIfPresent statusDirectory)
  forM_ files $ \file -> case NS.parseService (dropExtension file) of
    Right ns | takeExtension file == ".json" -> do
      current <- liftIO (readSaved statusVersion (statusFile (NS.serviceName ns)))
      unless (isJust (current :: Maybe Status)) . background . workload ns $ do
        outcome <- liftIO (stored ns) >>= applyState PSK.KeepLast ns Nothing
        persist ns outcome
        liftIO (publish ns outcome)
    _ -> pure ()

data Wake = Stopped | Pending | Idle

-- A request arrives while a previous connection is being served, or within
-- the idle period; otherwise systemd keeps the socket and starts netd again.
-- Only the wait times out, so an accepted connection is never dropped. Once
-- stopped, netd accepts nothing more and exits when its work is done, so a
-- restart never cuts a request short. Connections are numbered in the order
-- they are accepted.
acceptUntilIdle :: (Server es) => TVar Bool -> Socket -> Integer -> Eff es ()
acceptUntilIdle stopped listener n = do
  counter <- asks active
  wake <- liftIO $ do
    (readable, unregister) <- withFdSocket listener (threadWaitReadSTM . fromIntegral)
    idle <- registerDelay 60000000
    let stop = readTVar stopped >>= check
        timedOut = readTVar idle >>= check
    STM.atomically ((Stopped <$ stop) `orElse` (Pending <$ readable) `orElse` (Idle <$ timedOut))
      `E.finally` unregister
  case wake of
    Pending -> do
      -- A failed accept must not end netd while other requests are applied.
      accepted <- trySync (liftIO (accept listener))
      case accepted of
        Right (conn, _) -> background (answer n conn `finally` liftIO (close conn))
        Left err -> do
          logLine ("Could not accept a netd request: " ++ describe err)
          threadDelay 1000000
      acceptUntilIdle stopped listener (n + 1)
    Idle -> do
      busy <- readTVarIO counter
      unwritten <- asks pending >>= readTVarIO
      -- Key stores that could not be written are retried while netd stays.
      forM_ (Map.keys unwritten) $ \name -> background (locked name (pure ()))
      unless (busy == 0 && Map.null unwritten) (acceptUntilIdle stopped listener n)
    Stopped -> do
      liftIO (STM.atomically (readTVar counter >>= check . (== 0)))
      unwritten <- asks pending >>= readTVarIO
      forM_ (Map.keys unwritten) $ \name -> locked name (pure ())
      lost <- asks pending >>= readTVarIO
      unless (Map.null lost) . logLine $
        "Stopping with unwritten key stores for " ++ unwords (Map.keys lost)

-- Runs work in its own thread; netd does not go idle until it ends.
background :: (Server es) => Eff es () -> Eff es ()
background work = do
  counter <- asks active
  atomically (modifyTVar' counter (+ 1))
  let done result = do
        either (logLine . describe) pure result
        atomically (modifyTVar' counter (subtract 1))
  void (forkFinally work done)

-- Only root may manage workloads; the agent may send its own requests.
answer :: (Server es) => Integer -> Socket -> Eff es ()
answer n conn = do
  (_, uid, _) <- liftIO (getPeerCredential conn)
  received <- liftIO (timeout 10000000 (receiveAll conn))
  reply <- case eitherDecodeStrict' <$> received of
    Nothing -> pure (Failed "Timed out reading a netd request")
    Just (Left err) -> pure (Failed ("Invalid netd request: " ++ err))
    Just (Right r)
      | uid /= Just 0 && not (unprivileged r) -> pure (Failed "Netd request not permitted")
      | otherwise -> either (Failed . describe) (const Done) <$> trySync (perform n r)
  case reply of
    Failed message -> logLine message
    Done -> pure ()
  liftIO (sendAll conn (BL.toStrict (encode reply)))

-- `n` is the request's connection number.
perform :: (Server es) => Integer -> Request -> Eff es ()
perform n = \case
  Up ns -> workload ns (up ns)
  Down ns -> locked (NS.serviceName ns) (down ns)
  Apply ns -> workload ns (reapply ns)
  Desired ns desired -> workload ns (desire n ns desired)
  Address ns ident -> locked (NS.serviceName ns) (assign ns ident)
  Prune -> prune

-- Work on one workload never overlaps. It starts by writing the workload's
-- pending key stores. Work that reads them fails while they cannot be
-- written, so it never reads or replaces an older store.
workload :: (Server es) => NS.Workload -> Eff es a -> Eff es a
workload ns action = exclusive (NS.serviceName ns) $ do
  written <- flush (NS.serviceName ns)
  unless written (liftIO (fail "Could not write the workload's key stores"))
  action

-- Work that does not read the key stores goes on when they cannot be written.
locked :: (Server es) => String -> Eff es a -> Eff es a
locked name action = exclusive name (flush name >> action)

-- A store that cannot be written stays pending and is logged. Returns whether
-- every pending store was written.
flush :: (Server es) => String -> Eff es Bool
flush name = do
  queue <- asks pending
  writes <- atomically (stateTVar queue (\held -> (Map.findWithDefault Map.empty name held, Map.delete name held)))
  failed <- Map.traverseMaybeWithKey write writes
  unless (Map.null failed) $ atomically (modifyTVar' queue (Map.insertWith (flip Map.union) name failed))
  pure (Map.null failed)
  where
    write path contents = do
      result <- trySync (liftIO (durableWrite (Just 0o600) path contents))
      case result of
        Right () -> pure Nothing
        Left err -> Just contents <$ logLine ("Could not write " ++ path ++ ": " ++ describe err)

keysDirectory :: NS.Workload -> FilePath
keysDirectory ns = "/run/idr-mesh-keys" </> NS.serviceName ns

-- The instance netd assigned an address for; see `encodeState`.
instanceVersion :: Int
instanceVersion = 1

runtime, desiredFile, instanceFile :: NS.Workload -> FilePath
runtime = appliedDirectory . NS.serviceName
desiredFile ns = runtime ns </> "desired.json"
instanceFile ns = runtime ns </> "instance-id.json"

pskRoot :: FilePath
pskRoot = "/var/lib/idr-mesh-psk"

paths :: NS.Workload -> Apply.Paths
paths ns =
  Apply.Paths
    { Apply.settings = Inventory.settingsFile (NS.serviceName ns),
      Apply.keyStore = pskRoot </> NS.serviceName ns,
      Apply.pskStatus = runtime ns </> "psk.json"
    }

prepare :: NS.Workload -> IO ()
prepare ns = do
  createDirectoryIfMissing True (runtime ns)
  setFileMode (runtime ns) 0o700

stored :: NS.Workload -> IO (Maybe D.Desired)
stored = readState desiredVersion . desiredFile

-- Keys, namespace, link and port. A namespace recreated without a Down keeps
-- its keys, so it gets its registered address and peers back at once, unless
-- the workload now runs another service.
up :: (Server es) => NS.Workload -> Eff es ()
up ns = do
  liftIO (keys (keysDirectory ns) >> Netns.create ns (keysDirectory ns </> "private-key"))
  Config {firstPort, lastPort} <- asks config
  lock <- asks ports
  liftIO (withMVar lock (\_ -> Netns.allocatePort ns firstPort lastPort) >> prepare ns)
  service <- liftIO (settingsId <$> readJson (Apply.settings (paths ns)))
  registered <- liftIO (readState instanceVersion (instanceFile ns))
  case registered of
    Just (owner, ident) | owner == service -> address ns service ident
    Just _ -> liftIO (mapM_ removeIfExists [instanceFile ns, desiredFile ns])
    Nothing -> pure ()
  -- Up is not ordered after the secrets, so it keeps the last readable keys.
  liftIO (stored ns) >>= converge PSK.KeepLast ns Nothing

-- The next Up creates new keys. A peer that initiates then sees a new key and
-- starts a fresh handshake, instead of keeping a session with the removed link
-- until its next rekey. The stored desired state and the PSK report belong to
-- the removed key, so the next Up waits for the agent's desired state.
down :: (Server es) => NS.Workload -> Eff es ()
down ns = liftIO $ do
  removeIfExists (statusFile (NS.serviceName ns))
  Netns.remove ns
  removePathForcibly (keysDirectory ns)
  mapM_ removeIfExists [desiredFile ns, Apply.pskStatus (paths ns)]

-- Apply runs after the workload's secret targets, so an unreadable credential
-- revokes its link.
reapply :: (Server es) => NS.Workload -> Eff es ()
reapply ns = liftIO (prepare ns >> stored ns) >>= converge PSK.Revoke ns Nothing

-- A desired state that a newer connection overtook on its way to the
-- workload's lock changes nothing. The state is stored once it is applied, so
-- the next request compares against it even if publishing the status fails.
desire :: (Server es) => Integer -> NS.Workload -> D.Desired -> Eff es ()
desire n ns desired = do
  newest <- asks newest
  let name = NS.serviceName ns
      claim seen = (Map.lookup name seen, Map.insertWith max name n seen)
  before <- atomically (stateTVar newest claim)
  unless (any (> n) before) $ do
    previous <- liftIO (prepare ns >> stored ns)
    outcome <- applyState PSK.KeepLast ns previous (Just desired)
    persist ns outcome
    liftIO (atomicWritePrivate (desiredFile ns) (encodeState desiredVersion desired))
    liftIO (finish ns outcome)

assign :: (Server es) => NS.Workload -> InstanceId -> Eff es ()
assign ns ident = do
  service <- liftIO (prepare ns >> settingsId <$> readJson (Apply.settings (paths ns)))
  address ns service ident
  liftIO (atomicWritePrivate (instanceFile ns) (encodeState instanceVersion (service, ident)))

address :: (Server es) => NS.Workload -> ServiceId -> InstanceId -> Eff es ()
address ns service ident = do
  mesh <- asks (prefix . config)
  liftIO (Netns.configureAddress ns service mesh ident)

-- A workload's key stores and applied state go once it left the inventory
-- and is down.
prune :: (Server es) => Eff es ()
prune = do
  inventory <- liftIO Inventory.readInventory
  names <- liftIO (Set.fromList . concat <$> mapM listIfPresent [pskRoot, appliedRoot])
  forM_ (Set.filter (`Map.notMember` Inventory.services inventory) names) $ \name ->
    locked name $ do
      up' <- liftIO (doesFileExist (statusFile name))
      unless up' $ do
        liftIO (mapM_ (removePathForcibly . (</> name)) [pskRoot, appliedRoot])
        queue <- asks pending
        atomically (modifyTVar' queue (Map.delete name))

-- Without a desired state only declarations are applied.
converge ::
  (Server es) =>
  PSK.Unreadable ->
  NS.Workload ->
  Maybe D.Desired ->
  Maybe D.Desired ->
  Eff es ()
converge unreadable ns previous desired = do
  outcome <- applyState unreadable ns previous desired
  persist ns outcome
  liftIO (finish ns outcome)

applyState ::
  (Server es) =>
  PSK.Unreadable ->
  NS.Workload ->
  Maybe D.Desired ->
  Maybe D.Desired ->
  Eff es Apply.Outcome
applyState unreadable ns previous desired = do
  mesh <- asks (prefix . config)
  liftIO (Apply.apply unreadable ns mesh (paths ns) previous desired)

-- Writes the changed key stores durably in the background. An fsync can take
-- long, so the apply, its reply and other workloads do not wait for it. Work
-- already waiting for the workload writes them first, and netd stays until
-- they are written, or until it is stopped.
persist :: (Server es) => NS.Workload -> Apply.Outcome -> Eff es ()
persist ns outcome = do
  let writes = Map.fromList (Apply.keyStores outcome)
      name = NS.serviceName ns
  unless (null writes) $ do
    queue <- asks pending
    -- A later apply's contents replace an earlier one's.
    atomically (modifyTVar' queue (Map.insertWith Map.union name writes))
    background (locked name (pure ()))

-- Publishes the workload's status and DNS zone.
finish :: NS.Workload -> Apply.Outcome -> IO ()
finish ns outcome = do
  publish ns outcome
  zones <- readZones
  forM_ (Map.lookup (NS.serviceName ns) zones) $ \z ->
    Dns.writeZone (serverAddress z) (zone z) (Apply.installed outcome)

publish :: NS.Workload -> Apply.Outcome -> IO ()
publish ns outcome = do
  let status =
        Status
          (Apply.publicKey outcome)
          (Apply.listenPort outcome)
          (Apply.adverts outcome)
          (Apply.switchAt outcome)
  -- An unreadable status is replaced.
  current <- readSaved statusVersion (statusFile (NS.serviceName ns))
  unless (current == Just status) $
    atomicWriteWithMode 0o644 (statusFile (NS.serviceName ns)) (encodeState statusVersion status)

-- The DNS server address and zone file of each workload's view.
data Zone = Zone {serverAddress :: Text, zone :: FilePath} deriving (Generic)

instance FromJSON Zone

readZones :: IO (Map String Zone)
readZones = do
  -- The file is a symlink into the current system generation.
  inventory <- optionalFile (readJson "/etc/idr-mesh/dns.json")
  let services = parseEither (withObject "mesh DNS inventory" (.: "services"))
  maybe (pure Map.empty) (either fail pure . services) inventory
