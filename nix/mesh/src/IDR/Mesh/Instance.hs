{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- Registration and retirement of mesh instances. The agent runs one
-- registration per up workload; each workload's journal is changed only under
-- its lock.
module IDR.Mesh.Instance
  ( Registrar (..),
    Registration (..),
    Published (..),
    Registering,
    register,
    retire,
    registeredDirectory,
    registeredVersion,
  )
where

import Control.Concurrent.STM (TVar, readTVar, retry)
import Control.Monad (forM, forM_, forever, unless, when)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (concurrently_, mapConcurrently)
import Effectful.Concurrent.STM (atomically, readTVarIO)
import Effectful.Exception (finally, trySync)
import Effectful.Reader.Static (Reader, ask, asks)
import IDR.Mesh.Common (atomicWrite, describe, encodeState, listIfPresent, readJson, removeIfExists)
import IDR.Mesh.Duration (Seconds)
import IDR.Mesh.Effects
import IDR.Mesh.Etcd qualified as E
import IDR.Mesh.Etcd.Config (Server)
import IDR.Mesh.Etcd.Effect
import IDR.Mesh.Instance.Journal
import IDR.Mesh.Instance.Registry
import IDR.Mesh.Inventory qualified as Inventory
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.PeerData qualified as Peer
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

data Registrar = Registrar
  { prefix :: Peer.MeshPrefix,
    healthPort :: Int,
    leaseTTL :: Seconds,
    server :: Server
  }

-- What identifies a registration: the declared service and peer services, and
-- the workload's key. The agent registers again when any of it changes.
data Registration = Registration
  { declared :: (Peer.ServiceId, Set Peer.ServiceId),
    workloadKey :: Peer.PublicKey
  }
  deriving (Eq)

-- What a registration publishes besides its key. A change updates the
-- registration in place, on its lease.
data Published = Published
  { port :: Int,
    adverts :: Map Peer.ServiceId Peer.Advert,
    addresses :: [Text]
  }
  deriving (Eq)

type Registering es =
  ( Reader Registrar :> es,
    Locks :> es,
    Log :> es,
    Concurrent :> es,
    IOE :> es
  )

-- Journals and instance IDs survive reboots. Keys do not.
stateRoot :: FilePath
stateRoot = "/var/lib/idr-mesh-agent"

stateOf, journalOf, idFileOf, markerOf :: String -> FilePath
stateOf name = stateRoot </> name
journalOf name = stateOf name </> "registrations"
idFileOf name = stateOf name </> "instance-id"
markerOf name = registeredDirectory </> name

-- Each registered workload's file holds its instance ID.
registeredDirectory :: FilePath
registeredDirectory = "/run/idr-mesh-agent/registered"

-- See `encodeState`.
registeredVersion :: Int
registeredVersion = 1

-- Registers one workload until cancelled, retrying after failures.
register :: (Registering es) => NS.Workload -> Registration -> TVar Published -> Eff es a
register ns registration published =
  forever attempt `finally` liftIO (removeIfExists (markerOf (NS.serviceName ns)))
  where
    attempt = do
      result <- trySync (registerOnce ns registration published)
      either (logFailure (NS.serviceName ns)) pure result
      threadDelay 5000000

registerOnce :: (Registering es) => NS.Workload -> Registration -> TVar Published -> Eff es ()
registerOnce ns (Registration (service, peers) key) published = do
  Registrar {prefix, server, leaseTTL} <- ask
  liftIO (removeIfExists (markerOf name) >> createDirectoryIfMissing True (stateOf name))
  let identity ident = Attempt prefix service ident key
  markUnselected name identity
  withEtcd (E.withMeshEtcd server) $ do
    initial <- readTVarIO published
    value <- payload key initial
    let selected = checkSelection name prefix service peers
    Claim {claimed, lease, written} <-
      exclusive name (claim leaseTTL (journalOf name) (idFileOf name) identity value selected)
    keepAlive lease $ do
      liftIO $ do
        Netd.request (Netd.Address ns (instanceId claimed))
        atomicWrite (markerOf name) (encodeState registeredVersion (instanceId claimed))
      -- Keep renewing this lease even if retiring an old instance needs a new
      -- connection.
      concurrently_
        (republish key published claimed lease written initial)
        (retireOthers name claimed)
  where
    name = NS.serviceName ns

-- Marks the saved instance ID's intent for retirement if its service is no
-- longer selected.
markUnselected :: (Registering es) => String -> (Peer.InstanceId -> Attempt) -> Eff es ()
markUnselected name identity = do
  saved <- liftIO (savedInstanceId (idFileOf name))
  forM_ saved $ \ident -> exclusive name . liftIO $ do
    let file = attemptFile (journalOf name) (identity ident)
    intent <- readIntent file
    forM_ intent $ \i -> do
      inventory <- Inventory.readInventory
      when (unselected inventory name i) (markRetiring file)

-- The registration value.
payload :: (Reader Registrar :> es, IOE :> es) => Peer.PublicKey -> Published -> Eff es ByteString
payload key p = do
  health <- asks healthPort
  when (port p == health) $ liftIO (fail "Mesh health and WireGuard ports must differ")
  pure . BL.toStrict . encode $
    object
      [ "publicKey" .= key,
        "publicAddresses" .= addresses p,
        "peers" .= adverts p,
        "port" .= port p,
        "healthPort" .= health
      ]

-- The workload still runs this service, with these peers, in this mesh.
checkSelection :: String -> Peer.MeshPrefix -> Peer.ServiceId -> Set Peer.ServiceId -> IO ()
checkSelection name prefix service peers = do
  current <- readJson (Inventory.settingsFile name)
  inventory <- Inventory.readInventory
  let sameScope = selectedScope name inventory == Just (prefix, service)
      sameDeclarations =
        Peer.settingsId current == service
          && Map.keysSet (Peer.settingsPeers current) == peers
  unless (sameScope && sameDeclarations) $
    fail "Mesh service declarations changed during registration"

-- Republishes a changed value, only over the registration this agent wrote.
republish ::
  (Registering es, Etcd :> es) =>
  Peer.PublicKey ->
  TVar Published ->
  Attempt ->
  E.Lease ->
  E.Revision ->
  Published ->
  Eff es a
republish key published claimed lease = loop
  where
    slot = registrationKey claimed
    loop written current = do
      next <- atomically (readTVar published >>= \p -> if p == current then retry else pure p)
      value <- payload key next
      rewritten <- transaction [E.Modified slot written] [E.Put slot value (Just (E.leaseId lease))]
      case rewritten of
        Just revision -> loop revision next
        Nothing -> liftIO (fail "Mesh registration changed outside this agent")

-- Retires the workload's other journaled identities, for example its key from
-- before a reboot.
retireOthers :: (Registering es, Etcd :> es) => String -> Attempt -> Eff es ()
retireOthers name active =
  cleanupQueue (journalOf name) active $ \file -> exclusive name $ do
    intent <- liftIO (readIntent file)
    forM_ intent $ \i -> when (claimIdentity i /= active) $ do
      liftIO (markRetiring file)
      publishPending sameCluster file i

selectedScope :: String -> Inventory.Inventory -> Maybe (Peer.MeshPrefix, Peer.ServiceId)
selectedScope name inventory = do
  service <- Map.lookup name (Inventory.services inventory)
  pure (Inventory.ipv6Prefix inventory, Inventory.id service)

-- A registration ends when its workload no longer runs that service in that mesh.
unselected :: Inventory.Inventory -> String -> Intent -> Bool
unselected inventory name i =
  selectedScope name inventory /= Just (meshPrefix (claimIdentity i), serviceId (claimIdentity i))

-- netd deletes a workload's key when the workload goes down, so a registration
-- of any key other than the one netd publishes can never carry traffic again.
-- A restart that keeps the namespace keeps the key. A status file netd has
-- not rewritten for this release yet says nothing about the key.
stale :: Bool -> Maybe Netd.Status -> Intent -> Bool
stale present status i = case status of
  Just s -> Netd.publicKey s /= publicKey (claimIdentity i)
  Nothing -> not present

-- Retire registrations whose workload no longer runs that service in this
-- mesh or is down, and finish the retirements that are already pending.
-- Peers then drop a stopped instance at once instead of keeping it as absent.
-- Workloads are independent, so one held up by a long registration doesn't
-- delay the rest. Every retirement is attempted before the failures are
-- reported, so an old, inaccessible etcd prefix cannot starve the currently
-- selected scope.
retire :: (Registering es) => Eff es ()
retire = do
  names <- liftIO (listIfPresent stateRoot)
  failures <- concat <$> mapConcurrently retireWorkload names
  unless (null failures) $ liftIO (fail (unlines failures))

retireWorkload :: (Registering es) => String -> Eff es [String]
retireWorkload name = do
  listed <- trySync (liftIO (registrationFiles (journalOf name)))
  case listed of
    Left err -> pure [name ++ ": " ++ describe err]
    Right files -> do
      outcomes <- forM files $ \file -> (file,) <$> trySync (exclusive name (retireFile file))
      pure [file ++ ": " ++ describe err | (file, Left err) <- outcomes]
  where
    -- The inventory and status are read under the lock, so a registration
    -- that just claimed the slot again is not retired.
    retireFile file = do
      servers <- asks server
      inventory <- liftIO Inventory.readInventory
      present <- liftIO (doesFileExist (Netd.statusFile name))
      status <- liftIO (Netd.readStatus name)
      intent <- liftIO (readIntent file)
      forM_ intent $ \i -> do
        when (unselected inventory name i || stale present status i) (liftIO (markRetiring file))
        publishPending (withEtcd (E.withMeshEtcd servers)) file i
