{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- Each workload's mesh state for operators and monitoring, read from what the
-- agent and netd keep under /run and from the workload's WireGuard link. It
-- needs root to read netd's state and to enter the workload namespaces.
module IDR.Mesh.Status (printStatus, writeMetrics) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import IDR.Mesh.Addresses (addressesFile, addressesVersion)
import IDR.Mesh.Common (atomicWriteWithMode, readSaved, trySync)
import IDR.Mesh.Converge (snapshotDirectory)
import IDR.Mesh.Instance (registeredDirectory, registeredVersion)
import IDR.Mesh.Inventory qualified as Inventory
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.PeerData (InstanceId, MeshPrefix, ServiceId, instanceIdText, serviceIdText)
import IDR.Mesh.Peers (snapshotVersion)
import IDR.Mesh.Probe (Target, unhealthyFile, unhealthyVersion)
import IDR.Mesh.WireGuard qualified as WG
import System.FilePath ((<.>), (</>))

data Host = Host
  { publicAddresses :: Maybe [Text],
    unhealthyEndpoints :: [Target],
    workloads :: Map String Workload
  }
  deriving (Generic)

instance ToJSON Host

data Workload = Workload
  { service :: ServiceId,
    -- netd has its namespace up.
    up :: Bool,
    -- The instance the agent holds a registration for.
    instance' :: Maybe Text,
    discoveredRevision :: Maybe Integer,
    appliedRevision :: Maybe Integer,
    peers :: Peers,
    wireguard :: Maybe WireGuard,
    -- Only while the workload is up; netd keeps its last report after it stops.
    pskMismatches :: Maybe Int
  }
  deriving (Generic)

instance ToJSON Workload where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = filter (/= '\'')}

-- Discovered peer instances, by whether their registration is in etcd.
data Peers = Peers {present :: Int, absent :: Int} deriving (Generic)

instance ToJSON Peers

data WireGuard = WireGuard {installed :: Int, recentHandshakes :: Int} deriving (Generic)

instance ToJSON WireGuard where
  toJSON w = object ["peers" .= installed w, "recentHandshakes" .= recentHandshakes w]

-- A handshake this recent shows a live session: WireGuard renews it about
-- every two minutes while the link is kept alive.
recentSeconds :: Integer
recentSeconds = 180

collect :: IO Host
collect = do
  inventory <- Inventory.readInventory
  now <- floor <$> getPOSIXTime
  let prefix = Inventory.ipv6Prefix inventory
  states <- Map.traverseWithKey (workload now prefix) (Inventory.services inventory)
  addresses <- readSaved addressesVersion addressesFile
  unhealthy <- fromMaybe Set.empty <$> readSaved unhealthyVersion unhealthyFile
  pure
    Host
      { publicAddresses = addresses >>= parseMaybe (withObject "host addresses" (.: "publicAddresses")),
        unhealthyEndpoints = Set.toList unhealthy,
        workloads = states
      }

workload :: Integer -> MeshPrefix -> String -> Inventory.Service -> IO Workload
workload now prefix name declared = do
  status <- readSaved Netd.statusVersion (Netd.statusFile name) :: IO (Maybe Netd.Status)
  registered <- readSaved registeredVersion (registeredDirectory </> name) :: IO (Maybe InstanceId)
  snapshot <- readSaved snapshotVersion (snapshotDirectory </> name <.> "json") :: IO (Maybe Value)
  desired <- readSaved Netd.desiredVersion (Netd.appliedDirectory name </> "desired.json") :: IO (Maybe Value)
  psk <- readSaved Netd.pskStatusVersion (Netd.appliedDirectory name </> "psk.json") :: IO (Maybe [Value])
  link <- case (status, NS.parseService name) of
    -- The workload can go down while this reads its link.
    (Just _, Right ns) -> either (const Nothing) Just <$> trySync (WG.readInterface ns prefix)
    _ -> pure Nothing
  let presence = fromMaybe [] (snapshot >>= parseMaybe snapshotPresence)
      recent p = maybe False (\at -> now - at < recentSeconds) (WG.handshake p)
      linkPeers = Map.elems . WG.peers <$> link
  pure
    Workload
      { service = Inventory.id declared,
        up = maybe False (const True) status,
        instance' = instanceIdText <$> registered,
        discoveredRevision = snapshot >>= parseMaybe revision,
        appliedRevision = desired >>= parseMaybe revision,
        peers = Peers (length (filter id presence)) (length (filter not presence)),
        wireguard = (\ps -> WireGuard (length ps) (length (filter recent ps))) <$> linkPeers,
        pskMismatches = length (mapMaybe (parseMaybe mismatch) (fromMaybe [] psk)) <$ status
      }
  where
    revision = withObject "mesh state" (.: "revision") :: Value -> Parser Integer
    snapshotPresence = withObject "mesh peer snapshot" $ \o ->
      o .: "peers" >>= traverse (withObject "mesh peer" (.: "registrationPresent"))
    -- An entry whose installed key is not the agreed one, or that has none.
    mismatch = withObject "mesh PSK status" $ \o -> do
      installedKey <- o .: "installed" :: Parser Value
      agreedKey <- o .:? "agreed" :: Parser (Maybe Value)
      if agreedKey == Just installedKey then fail "agreed" else pure ()

printStatus :: IO ()
printStatus = collect >>= BLC.putStrLn . encode

-- Prometheus text for node-exporter's textfile collector, replaced atomically.
writeMetrics :: FilePath -> IO ()
writeMetrics path = do
  host <- collect
  atomicWriteWithMode 0o644 path (BC.pack (metrics host))

metrics :: Host -> String
metrics host =
  concat
    [ family "idr_mesh_workload_up" "Whether netd has the workload's mesh namespace up." $
        each (\w -> [([], flag (up w))]),
      family "idr_mesh_workload_registered" "Whether the agent holds the workload's registration in etcd." $
        each (\w -> [([], flag (maybe False (const True) (instance' w)))]),
      family "idr_mesh_discovered_revision" "etcd revision of the workload's latest peer snapshot." $
        each (\w -> [([], fromInteger r) | Just r <- [discoveredRevision w]]),
      family "idr_mesh_applied_revision" "etcd revision of the desired state netd applied last." $
        each (\w -> [([], fromInteger r) | Just r <- [appliedRevision w]]),
      family "idr_mesh_peers" "Discovered peer instances, by whether their registration is in etcd." $
        each (\w -> [([("state", "present")], present (peers w)), ([("state", "absent")], absent (peers w))]),
      family "idr_mesh_wireguard_peers" "WireGuard peers installed for the workload." $
        each (\w -> [([], installed g) | Just g <- [wireguard w]]),
      family "idr_mesh_wireguard_recent_handshakes" "Installed peers with a handshake in the last 180 seconds." $
        each (\w -> [([], recentHandshakes g) | Just g <- [wireguard w]]),
      family "idr_mesh_psk_mismatches" "Installed peers whose PSK is not the agreed one." $
        each (\w -> [([], n) | Just n <- [pskMismatches w]]),
      family "idr_mesh_public_addresses" "Public addresses the host advertises." $
        [([], maybe 0 length (publicAddresses host))],
      family "idr_mesh_unhealthy_endpoints" "Peer endpoints that fail their health check." $
        [([], length (unhealthyEndpoints host))]
    ]
  where
    flag b = if b then 1 else 0
    each sample =
      [ (("workload", T.pack name) : ("service", serviceIdText (service w)) : labels, value)
      | (name, w) <- Map.toList (workloads host),
        (labels, value) <- sample w
      ]

family :: String -> String -> [([(Text, Text)], Int)] -> String
family name help samples =
  unlines $
    ["# HELP " ++ name ++ " " ++ help, "# TYPE " ++ name ++ " gauge"]
      ++ [name ++ labelSet labels ++ " " ++ show value | (labels, value) <- samples]
  where
    labelSet [] = ""
    labelSet labels = "{" ++ T.unpack (T.intercalate "," [k <> "=\"" <> escape v <> "\"" | (k, v) <- labels]) ++ "}"
    escape = T.concatMap (\c -> case c of '\\' -> "\\\\"; '"' -> "\\\""; '\n' -> "\\n"; _ -> T.singleton c)
