{-# LANGUAGE DataKinds #-}

-- The agent's side of convergence for one workload: discovery, the desired
-- state derived from it, and handing that state to netd.
module IDR.Mesh.Converge (Shared (..), Scope (..), Converging, converge, snapshotDirectory) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (STM, TVar, check, modifyTVar', orElse, readTVar, retry, writeTVar)
import Control.Monad (forever, guard, when)
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (mapConcurrently_)
import Effectful.Concurrent.STM (atomically, newTVarIO, registerDelay)
import Effectful.Exception (finally, trySync)
import Effectful.Reader.Static (Reader, ask, asks)
import IDR.Mesh.Desired qualified as D
import IDR.Mesh.Effects (Log, logFailure)
import IDR.Mesh.Instance (Registrar (..))
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.PSK qualified as PSK
import IDR.Mesh.PeerData
import IDR.Mesh.Peers (Discovery (Discovery), discover)
import IDR.Mesh.Probe (Target (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((<.>), (</>))

-- Host-wide inputs of every workload's desired state.
data Shared = Shared
  { -- The advertised public addresses, once collected.
    addresses :: TVar (Maybe [Text]),
    -- Bumped when the local transport changes, so endpoints are set again and
    -- WireGuard picks a new source address.
    transport :: TVar Int,
    unhealthy :: TVar (Set Target),
    -- The peer addresses each workload initiates to, for the prober.
    targets :: TVar (Map String [[Target]])
  }

-- What a workload's discovery follows. A change restarts it.
data Scope = Scope {own :: ServiceId, declared :: [ServiceId], key :: PublicKey}
  deriving (Eq)

-- Retained snapshots survive an agent restart, so peers stay usable while
-- etcd is unreachable.
snapshotDirectory :: FilePath
snapshotDirectory = "/run/idr-mesh-agent/peers"

-- The configuration and host-wide state a workload's convergence reads.
type Converging es =
  (Reader Registrar :> es, Reader Shared :> es, Log :> es, Concurrent :> es, IOE :> es)

-- Sends the desired state whenever it changes, and again when a PSK switch
-- netd deferred may proceed, until cancelled. `switchAt` follows the
-- workload's netd status.
converge :: (Converging es) => NS.Workload -> Scope -> TVar (Maybe Integer) -> Eff es ()
converge ns scope switchAt = do
  liftIO (createDirectoryIfMissing True snapshotDirectory)
  snapshot <- newTVarIO Nothing
  due <- newTVarIO False
  forTargets <- asks targets
  mapConcurrently_
    id
    [ discovering ns scope snapshot,
      alarm switchAt due,
      send ns scope snapshot due Nothing
    ]
    `finally` atomically (modifyTVar' forTargets (Map.delete (NS.serviceName ns)))

-- Discovery publishes each snapshot; it restarts five seconds after a failure.
discovering :: (Converging es) => NS.Workload -> Scope -> TVar (Maybe Snapshot) -> Eff es a
discovering ns scope snapshot = forever $ do
  Registrar {prefix, server} <- ask
  let name = NS.serviceName ns
      cache = snapshotDirectory </> name <.> "json"
      discovery = Discovery prefix (key scope) (own scope) (declared scope) cache
  result <- trySync (discover server discovery (atomically . writeTVar snapshot . Just))
  either (logFailure (name ++ ": could not discover peers")) pure result
  threadDelay 5000000

-- Raises `due` once a deferred PSK switch may proceed, then waits until netd
-- has handled it. The time is in netd's status, so it survives a restart of
-- either process.
alarm :: (Converging es) => TVar (Maybe Integer) -> TVar Bool -> Eff es a
alarm switchAt due = forever $ do
  at <- atomically (readTVar switchAt >>= maybe retry pure)
  now <- liftIO getPOSIXTime
  elapsed <- registerDelay (max 0 (ceiling ((fromInteger at - now) * 1000000)))
  let moved = readTVar switchAt >>= check . (/= Just at)
  atomically (moved `orElse` (readTVar elapsed >>= check >> writeTVar due True))
  -- netd normally publishes another time or none. If it keeps this one, for
  -- example after a clock step, the alarm arms again after five seconds.
  settled <- registerDelay 5000000
  atomically (moved `orElse` (readTVar settled >>= check))

-- Hands each new desired state to netd, retrying every five seconds. netd's
-- state is unknown after a failure, so the retry sends even an unchanged
-- state.
send ::
  (Converging es) =>
  NS.Workload ->
  Scope ->
  TVar (Maybe Snapshot) ->
  TVar Bool ->
  Maybe (D.Desired, Int) ->
  Eff es a
send ns scope snapshot due sent = do
  shared <- ask
  (desired, epoch, initiated) <- atomically (nextDesired scope shared snapshot due sent)
  atomically (modifyTVar' (targets shared) (Map.insert (NS.serviceName ns) initiated))
  result <- trySync (liftIO (Netd.request (Netd.Desired ns desired)))
  case result of
    Right () -> send ns scope snapshot due (Just (desired, epoch))
    Left err -> do
      logFailure (NS.serviceName ns ++ ": could not apply the desired state") err
      threadDelay 5000000
      send ns scope snapshot due Nothing

-- Waits until the desired state or the transport epoch differs from what was
-- sent last, or a deferred switch is due, and returns it with the peer
-- addresses to probe.
nextDesired ::
  Scope ->
  Shared ->
  TVar (Maybe Snapshot) ->
  TVar Bool ->
  Maybe (D.Desired, Int) ->
  STM (D.Desired, Int, [[Target]])
nextDesired scope shared snapshot due sent = do
  current <- readTVar snapshot >>= maybe retry pure
  inbound <- maybe True (not . null) <$> readTVar (addresses shared)
  failing <- readTVar (unhealthy shared)
  epoch <- readTVar (transport shared)
  let desired = desiredState scope inbound failing current
  again <- readTVar due
  when (sent == Just (desired, epoch) && not again) retry
  writeTVar due False
  pure (desired, epoch, initiatedTargets scope inbound current)

-- A pure function of the snapshot, the health set and whether the host
-- accepts inbound handshakes. Each end decides the PSK from its own published
-- advert and the peer's advert for this service, both read at one revision.
desiredState :: Scope -> Bool -> Set Target -> Snapshot -> D.Desired
desiredState scope inbound failing s =
  D.Desired
    { D.revision = snapRevision s,
      D.published = foldMap peerAdverts self,
      D.peers = map peer (sortOn peerSlot (snapPeers s))
    }
  where
    self = snapSelf s
    peer p =
      D.Peer
        { D.service = peerServiceId p,
          D.instanceId = peerInstanceId p,
          D.publicKey = peerPublicKey p,
          D.accepts = accepts scope p,
          D.agreed = agreed p,
          D.present = peerPresent p && any peerPresent self,
          D.endpoint = endpoint p
        }
    -- Needs this end's advert for the peer's service and the peer's advert
    -- for this one.
    agreed p = do
      ours <- self >>= advertFor (peerServiceId p)
      theirs <- advertFor (own scope) p
      PSK.agreed (key scope, ours) (peerPublicKey p, theirs)
    -- The initiator uses the peer's first healthy advertised address, or its
    -- first address when none is healthy; the other end learns the return
    -- endpoint.
    endpoint p = do
      guard (initiates inbound (key scope) p)
      let healthy a = Set.notMember (Target a (peerHealthPort p)) failing
      address <- find healthy (peerAddresses p) <|> listToMaybe (peerAddresses p)
      pure (D.Endpoint address (peerPort p))

accepts :: Scope -> Peer -> Bool
accepts scope p = Map.member (own scope) (peerAdverts p)

-- The addresses, in priority order, of every accepting peer this end initiates to.
initiatedTargets :: Scope -> Bool -> Snapshot -> [[Target]]
initiatedTargets scope inbound s =
  [ map (`Target` peerHealthPort p) (peerAddresses p)
  | p <- snapPeers s,
    accepts scope p,
    initiates inbound (key scope) p
  ]
