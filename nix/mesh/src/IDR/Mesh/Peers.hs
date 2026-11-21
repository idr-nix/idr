{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Peers (Discovery (..), discover, snapshotVersion) where

import Control.Monad (filterM, join, unless, when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Either (lefts, rights)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find, sortOn, (\\))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful
import Effectful.Exception (throwIO, trySync)
import IDR.Mesh.Common (atomicWrite, encodeState, readStateWith)
import IDR.Mesh.Etcd qualified as E
import IDR.Mesh.Etcd.Config (Server)
import IDR.Mesh.Etcd.Effect
import IDR.Mesh.Etcd.Types (toRevision)
import IDR.Mesh.PeerData
import MAlonzo.Code.IDR.Mesh.Foreign qualified as Retention

-- A workload watches its declared peer services and its own service, whose
-- registration carries the PSK adverts it published.
data Discovery = Discovery
  { prefix :: MeshPrefix,
    localKey :: PublicKey,
    own :: ServiceId,
    declared :: [ServiceId],
    -- The retained snapshot.
    cache :: FilePath
  }

-- Publishes the retained snapshot first, so peers stay usable while etcd is
-- unreachable, and then every refresh. It runs until the watch fails.
discover :: (IOE :> es) => Server -> Discovery -> (Snapshot -> Eff es ()) -> Eff es ()
discover server d publish = do
  previous <- liftIO (retained d)
  mapM_ publish previous
  withEtcd (E.withMeshEtcd server) $ do
    initial <- refreshSnapshot d (raise . publish) previous Nothing
    watchPeers d (raise . publish) initial

-- See `encodeState`.
snapshotVersion :: Int
snapshotVersion = 1

retained :: Discovery -> IO (Maybe Snapshot)
retained d = join <$> readStateWith snapshotVersion (parseScopedSnapshot (prefix d) (localKey d)) (cache d)

watchedServices :: Discovery -> [ServiceId]
watchedServices d = Set.toList (Set.fromList (own d : declared d))

data Observation
  = Registered Peer
  | Retired Retirement

-- A malformed record: a whole registration slot, or one key in that slot.
type Malformed = (ServiceId, InstanceId, Maybe PublicKey)

-- Keys outside the mesh layout name no record and are ignored. A malformed
-- record yields what it names.
decodeEntry :: MeshPrefix -> ServiceId -> E.Entry -> Maybe (Either Malformed Observation)
decodeEntry mesh service entry = do
  suffix <- T.stripPrefix (servicePrefix mesh service) (E.entryKey entry)
  case T.splitOn "/" suffix of
    ["instances", rawId] -> do
      i <- hush (parseInstanceId rawId)
      let registration = do
            leased
            value <- eitherDecodeStrict' bytes
            parseEither (parseRegistration mesh service i rev) value
      pure (either (const (Left (service, i, Nothing))) (Right . Registered) registration)
    ["retirements", rawId, keyId] -> do
      i <- hush (parseInstanceId rawId)
      key <- hush (publicKeyFromHex keyId)
      pure $
        if BS.null bytes
          then Right (Retired (Retirement service i (meshAddress mesh service i) key rev))
          else Left (service, i, Just key)
    _ -> Nothing
  where
    rev = E.entryRevision entry
    bytes = E.entryValue entry
    leased = unless (isJust (E.entryLease entry)) (Left "Mesh registration without a lease")
    hush = either (const Nothing) Just

-- Reads every watched service at one revision and keeps what retention allows.
refreshSnapshot ::
  (Etcd :> es, IOE :> es) =>
  Discovery ->
  (Snapshot -> Eff es ()) ->
  Maybe Snapshot ->
  Maybe E.Revision ->
  Eff es Snapshot
refreshSnapshot d publish previous eventRevision = do
  (revision, services, denied) <- readServices d
  when (any (> revision) eventRevision) $ liftIO (fail "Etcd snapshot is behind its watch event")
  cluster <- clusterId
  first <- liftIO (toRevision 1)
  -- Another cluster's revisions are not comparable, nor are revisions from
  -- before a cluster was restored to an older one. Such a snapshot's peers
  -- stay, absent, until the cluster registers them again, and count as older
  -- than any of its revisions, so a saved snapshot stays readable. A restore
  -- that keeps revisions comparable passes `--bump-revision` and
  -- `--mark-compacted` to `etcdutl snapshot restore`: watches then end as
  -- compacted and discovery starts over. Without them, a restored cluster
  -- reuses revisions, and this only helps until it passes the old ones.
  let earliest p = p {peerRevision = first}
      adopt s
        | snapCluster s == cluster && snapRevision s <= revision = s
        | otherwise = Snapshot cluster first (earliest <$> snapSelf s) (map earliest (snapPeers s)) []
      carried = adopt <$> previous
  let decodeService (service, entries) = mapMaybe (decodeEntry (prefix d) service) entries
      decoded = concatMap decodeService services
      snapshot = retain d cluster revision (rights decoded) (Set.fromList (lefts decoded)) carried
  liftIO (saveSnapshot d snapshot)
  publish snapshot
  -- Discovery restarts until it may read every watched service again.
  unless (null denied) . liftIO . fail $
    "No etcd access to mesh services " ++ unwords (map (T.unpack . serviceIdText) denied)
  pure snapshot

-- Reads the watched services at one revision. A service the agent may not
-- read, for example while its role is updated, is left out; retention then
-- keeps its peers, absent, as after a lost registration. Returns those
-- services too.
readServices ::
  (Etcd :> es, IOE :> es) =>
  Discovery ->
  Eff es (E.Revision, [(ServiceId, [E.Entry])], [ServiceId])
readServices d = do
  let serviceEntries s = (s,) <$> E.prefix (servicePrefix (prefix d) s)
      readAll services = readSnapshot (traverse serviceEntries services)
      readable s = either (not . E.permissionDenied) (const True) <$> trySync (readAll [s])
      watched = watchedServices d
  attempt <- trySync (readAll watched)
  case attempt of
    Right (revision, services) -> pure (revision, services, [])
    Left err | E.permissionDenied err -> do
      permitted <- filterM readable watched
      (revision, services) <- readAll permitted
      pure (revision, services, watched \\ permitted)
    Left err -> throwIO err

-- The Agda reconciliation kernel selects peers before the cache is sorted for
-- publication. Malformed slots, keys claimed twice and retired peers fail
-- closed; retirement markers stay as evidence for consumers. The own
-- registration is kept, marked absent, while etcd no longer lists it.
retain ::
  Discovery ->
  E.ClusterId ->
  E.Revision ->
  [Observation] ->
  Set.Set Malformed ->
  Maybe Snapshot ->
  Snapshot
retain d cluster revision records malformed previous =
  Snapshot cluster revision self peers retirements
  where
    fresh = [p | Registered p <- records]
    valid p =
      let (service, i) = peerSlot p
          slot key = (service, i, key)
       in all ((`Set.notMember` malformed) . slot) [Nothing, Just (peerPublicKey p)]
    claims = Map.fromListWith (+) [(peerPublicKey p, 1 :: Int) | p <- fresh]
    freshAddresses = Set.fromList (map peerAddress fresh)
    services = Set.fromList (declared d)
    stillDeclared p = Set.member (peerServiceId p) services
    -- A malformed slot also drops the cached peer it held.
    admissible p =
      valid p
        && peerPublicKey p /= localKey d
        && stillDeclared p
        && Map.findWithDefault 0 (peerPublicKey p) claims <= 1
    keyUnclaimed p = Map.notMember (peerPublicKey p) claims
    addressUnclaimed p = Set.notMember (peerAddress p) freshAddresses
    markAbsent p = p {peerPresent = False}
    reconcile =
      Retention.reconcile () admissible stillDeclared keyUnclaimed addressUnclaimed markAbsent
    peers = filter (not . peerRetired retirements) (reconcile fresh (foldMap snapPeers previous))
    ownRegistration p = peerServiceId p == own d && peerPublicKey p == localKey d
    self = case find (\p -> ownRegistration p && valid p) fresh of
      Just p -> Just p
      Nothing -> markAbsent <$> (previous >>= snapSelf)
    -- Markers expire after every connected host has applied them, so the cache
    -- mirrors the markers that etcd still holds.
    retirements = [r | Retired r <- records]

saveSnapshot :: Discovery -> Snapshot -> IO ()
saveSnapshot d s = do
  atomicWrite (cache d) . encodeState snapshotVersion $
    object
      [ "ipv6Prefix" .= prefix d,
        "ownPublicKey" .= localKey d,
        "clusterId" .= snapCluster s,
        "revision" .= snapRevision s,
        "self" .= snapSelf s,
        "peers" .= sortOn peerSlot (snapPeers s),
        "retirements" .= snapRetirements s
      ]

-- Each event newer than the latest snapshot triggers a full refresh.
watchPeers ::
  (Etcd :> es, IOE :> es) =>
  Discovery ->
  (Snapshot -> Eff es ()) ->
  Snapshot ->
  Eff es ()
watchPeers d publish initial = do
  latest <- liftIO (newIORef initial)
  let prefixes = map (servicePrefix (prefix d)) (watchedServices d)
      update events = do
        current <- liftIO (readIORef latest)
        let newer = filter (> snapRevision current) (map snd events)
        unless (null newer) $ do
          next <- refreshSnapshot d publish (Just current) (Just (maximum newer))
          liftIO (writeIORef latest next)
  watch (snapRevision <$> liftIO (readIORef latest)) prefixes update
