{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- netd's side of convergence for one workload: declarations, routes, key
-- stores and WireGuard peers. The agent's desired state can only name
-- instances of declared services; netd derives their addresses and chooses
-- every secret.
module IDR.Mesh.Apply (Paths (..), Outcome (..), apply, forwarded) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import IDR.Mesh.Common
import IDR.Mesh.Desired qualified as D
import IDR.Mesh.IP (parseIP)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.PSK qualified as PSK
import IDR.Mesh.PSK.Secret (Secret, secretHash, secretKey)
import IDR.Mesh.PeerData
import IDR.Mesh.WireGuard qualified as WG

-- Where one workload's declarations, PSK key stores and PSK status live.
data Paths = Paths {settings, keyStore, pskStatus :: FilePath}

data Outcome = Outcome
  { -- The workload's own WireGuard key.
    publicKey :: PublicKey,
    listenPort :: Int,
    -- The PSK adverts this configuration wants published.
    adverts :: Map ServiceId Advert,
    -- The key store files to write, whose kept keys changed.
    keyStores :: [(FilePath, ByteString)],
    -- When the earliest PSK switch that waits for its handshake window may
    -- proceed, in seconds since the epoch.
    switchAt :: Maybe Integer,
    -- The installed and the linked peers, by service and mesh address.
    installed :: [(ServiceId, Text)],
    -- The names that resolve to those peers, with their mesh addresses.
    named :: [(Text, Text)],
    -- The linked workloads, and the installed peer services this workload
    -- forwards for each.
    forwarding :: [(String, [ServiceId])]
  }

-- A desired peer netd installs, with the address netd derived for it.
data Install = Install
  { peer :: D.Peer,
    address :: Text,
    keys :: PSK.Keys,
    target :: Maybe Text
  }

-- Without a desired state only declarations, routes and key stores are
-- applied. The previous desired state tells which endpoints moved.
apply ::
  PSK.Unreadable ->
  NS.Workload ->
  Paths ->
  Maybe D.Desired ->
  Maybe D.Desired ->
  IO Outcome
apply unreadable ns paths previous desired = do
  configured <- readJson (settings paths)
  let prefix = settingsPrefix configured
      declarations = settingsPeers configured
      declared = Map.keysSet declarations
      -- Peers on this machine in other meshes, at their local instance.
      linked = Map.toList (settingsLinks configured)
      linkAddress (service, link) = meshAddress (linkPrefix link) service localInstance
      linkPeers = [(service, linkAddress l) | l@(service, _) <- linked]
      linkNamed = [(name, linkAddress l) | l@(_, link) <- linked, name <- linkNames link]
  interface <- WG.readInterface ns prefix
  current <- revokeUndeclared ns declared (WG.peers interface)
  reconcileRoutes ns prefix declared
  (stores, changed) <- PSK.syncKeys unreadable (keyStore paths) declarations desired
  let ownKey = WG.ownKey interface
      outcome switch installed' named' =
        Outcome ownKey (WG.listenPort interface) (fmap PSK.advert stores) changed switch installed' named' (forwarded configured)
  case desired of
    Nothing -> pure (outcome Nothing linkPeers linkNamed)
    Just d -> do
      peers <- installable prefix declared ownKey stores d
      later <- install ns paths current (maybe Set.empty (moved d) previous) peers
      let names i = Map.findWithDefault [] (D.service (peer i)) (settingsNames configured)
      pure . outcome later ([(D.service (peer i), address i) | i <- peers] ++ linkPeers) $
        [(name, address i) | i <- peers, name <- names i] ++ linkNamed

-- The linked workloads that this one forwards peer services for, with those
-- services.
forwarded :: Settings -> [(String, [ServiceId])]
forwarded configured =
  [(workload, linkForwards link) | link <- Map.elems (settingsLinks configured), Just workload <- [linkWorkload link], not (null (linkForwards link))]

-- Revoke undeclared peers even when the desired state or runtime secrets are
-- unavailable. Returns the peers that remain.
revokeUndeclared ::
  NS.Workload ->
  Set ServiceId ->
  Map PublicKey WG.Peer ->
  IO (Map PublicKey WG.Peer)
revokeUndeclared ns declared current = do
  let allowed = maybe False ((`Set.member` declared) . WG.subnetServiceId) . WG.subnet
      (kept, revoked) = Map.partition allowed current
  WG.removePeers ns (Map.keys revoked)
  pure kept

-- The desired peers this workload may install: their service is declared and
-- grants it, and a usable key is stored for it.
installable ::
  MeshPrefix ->
  Set ServiceId ->
  PublicKey ->
  Map ServiceId PSK.Keys ->
  D.Desired ->
  IO [Install]
installable prefix declared ownKey stores d = do
  let candidates =
        [ (p, store)
        | p <- D.peers d,
          D.accepts p,
          Set.member (D.service p) declared,
          D.publicKey p /= ownKey,
          Just store <- [Map.lookup (D.service p) stores]
        ]
      chosen = map fst candidates
      slots = [(D.service p, D.instanceId p) | p <- chosen]
  unless (unique (map D.publicKey chosen) && unique slots) $
    fail "Duplicate peer key or address in desired mesh state"
  forM candidates $ \(p, store) ->
    Install p (meshAddress prefix (D.service p) (D.instanceId p)) store
      <$> traverse renderEndpoint (D.endpoint p)

-- An initiator whose endpoint moved starts over with a fresh peer, which
-- handshakes with the new endpoint at once. Otherwise the other end can keep
-- roaming it back to a failed address with handshakes sent from there, and
-- while it answers those it never sends its own.
moved :: D.Desired -> D.Desired -> Set PublicKey
moved new old =
  Set.fromList
    [ D.publicKey p
    | p <- D.peers new,
      Just to <- [D.endpoint p],
      Just from <- [Map.lookup (D.publicKey p) before],
      to /= from
    ]
  where
    before = Map.fromList [(D.publicKey p, e) | p <- D.peers old, Just e <- [D.endpoint p]]

-- Removes the peers whose address changed and the restarted ones, then
-- configures every installable peer. A restarted peer keeps its installed key
-- and handshake time, so the switch rules still apply to it.
install ::
  NS.Workload ->
  Paths ->
  Map PublicKey WG.Peer ->
  Set PublicKey ->
  [Install] ->
  IO (Maybe Integer)
install ns paths current restart peers = do
  let addresses = Map.fromList [(D.publicKey (peer i), address i) | i <- peers]
      kept key = maybe False ((Map.lookup key addresses ==) . Just . WG.subnetAddress) . WG.subnet
      stale = Map.keysSet (Map.filterWithKey (\key -> not . kept key) current)
      remaining = Map.withoutKeys current stale
  WG.removePeers ns (Set.toList (Set.union stale restart))
  now <- floor <$> getPOSIXTime
  let decisions = map (decide now remaining) peers
  unless (null decisions) $
    WG.addConfiguration ns (T.intercalate "\n" (map entry decisions))
  atomicWrite (pskStatus paths) (encodeState Netd.pskStatusVersion (map report decisions))
  pure (minimum <$> NE.nonEmpty (mapMaybe waits decisions))

-- A peer's configuration and PSK report, and when a key switch that waits may
-- proceed.
data Decision = Decision {entry :: Text, report :: Value, waits :: Maybe Integer}

-- A new peer gets the agreed key, or the wanted key when there is none. An
-- installed key changes only to the agreed key, and only within the switch
-- window.
decide :: Integer -> Map PublicKey WG.Peer -> Install -> Decision
decide now installed candidate =
  Decision (peerConfig key secret (address candidate) (target candidate)) report' waiting
  where
    p = peer candidate
    store = keys candidate
    key = D.publicKey p
    current = Map.lookup key installed >>= WG.presharedKey
    chosen = PSK.target (secretHash <$> current) (D.present p) (PSK.advert store) (D.agreed p)
    switching = any ((/= chosen) . secretHash) current
    closed = closedUntil now (Map.lookup key installed >>= WG.handshake)
    waiting = if switching then closed else Nothing
    blocked = isJust waiting
    next = if blocked then maybe chosen secretHash current else chosen
    known = toList (PSK.secrets store) ++ maybeToList current
    fallback = fromMaybe (NE.head (PSK.secrets store)) current
    secret = fromMaybe fallback (find ((== next) . secretHash) known)
    report' =
      object
        [ "publicKey" .= key,
          "installed" .= secretHash secret,
          "wanted" .= wanted (PSK.advert store),
          "agreed" .= D.agreed p
        ]

-- An installed key changes within 60 seconds after a handshake, so the other
-- end has time to follow before the next rekey about 120 seconds in. Once that
-- rekey is due it changes too: the other end may have switched already, and
-- the running session stays valid until 180 seconds while WireGuard retries
-- the handshake. Without a handshake there is no session to keep. Returns
-- when the window opens again while it is closed.
closedUntil :: Integer -> Maybe Integer -> Maybe Integer
closedUntil now (Just at) | now - at >= 60 && now - at < 120 = Just (at + 120)
closedUntil _ _ = Nothing

-- The initiator sets the endpoint and keeps the session alive; the other end
-- learns its endpoint from the handshake.
peerConfig :: PublicKey -> Secret -> Text -> Maybe Text -> Text
peerConfig key secret address' endpoint =
  T.unlines $
    [ "[Peer]",
      "PublicKey = " <> publicKeyText key,
      "PresharedKey = " <> secretKey secret,
      "AllowedIPs = " <> address' <> "/128"
    ]
      ++ case endpoint of
        Just to -> ["Endpoint = " <> to, "PersistentKeepalive = 25"]
        Nothing -> ["PersistentKeepalive = 0"]

-- An endpoint as WireGuard writes it, with brackets around IPv6 addresses.
renderEndpoint :: D.Endpoint -> IO Text
renderEndpoint (D.Endpoint host port) = do
  ip <- maybe (fail "Invalid mesh peer endpoint address") pure (parseIP (T.unpack host))
  unless (1 <= port && port <= 65535) $ fail "Invalid mesh peer endpoint port"
  let rendered = T.pack (show ip)
      bracketed = if T.any (== ':') rendered then "[" <> rendered <> "]" else rendered
  pure (bracketed <> ":" <> T.pack (show port))

-- Routes ---------------------------------------------------------------------

data RouteChange = AddRoute ServiceId | RemoveRoute Text Int

-- One /96 route per declared service. Routes with a gateway, source or
-- nexthop are not ours; a duplicated or zero metric is refused.
routeChanges :: MeshPrefix -> Set ServiceId -> [Object] -> Parser [RouteChange]
routeChanges prefix declared routes = do
  managed <- catMaybes <$> traverse inspect routes
  let present = Set.fromList [s | (s, _, _) <- managed]
      removals = [RemoveRoute dst metric | (s, dst, metric) <- managed, Set.notMember s declared]
  pure (removals ++ map AddRoute (Set.toList (Set.difference declared present)))
  where
    routeKey o = (KM.lookup "dst" o, KM.lookup "metric" o)
    counts = Map.fromListWith (+) [(routeKey o, 1 :: Int) | o <- routes]
    foreign' o = any (`KM.member` o) ["from", "gateway", "via", "nhid", "nexthops"]
    inspect o
      | foreign' o = pure Nothing
      | otherwise = do
          dst <- o .:? "dst" .!= ""
          case WG.serviceRoute prefix dst of
            Nothing -> pure Nothing
            Just service -> do
              metric <- o .: "metric"
              unless (metric > 0 && Map.lookup (routeKey o) counts == Just 1) $
                fail "Invalid or ambiguous metric on managed mesh route"
              pure (Just (service, dst, metric))

reconcileRoutes :: NS.Workload -> MeshPrefix -> Set ServiceId -> IO ()
reconcileRoutes ns prefix declared = do
  let table = ["table", "main", "dev", "idr-mesh", "proto", "static"]
      route action dst extra = ["ip", "-6", "route", action, T.unpack dst] ++ table ++ extra
      serviceRange service = meshAddress prefix service (instanceIdFromWord32 0) <> "/96"
  let listing = ["ip", "-json", "-6", "route", "show"] ++ table ++ ["type", "unicast"]
  routes <- NS.json (NS.Pinned ns) listing
  changes <- either fail pure (parseEither (routeChanges prefix declared) routes)
  forM_ changes $ \case
    RemoveRoute dst metric -> NS.run (NS.Pinned ns) (route "del" dst ["metric", show metric])
    AddRoute service -> NS.run (NS.Pinned ns) (route "add" (serviceRange service) [])
