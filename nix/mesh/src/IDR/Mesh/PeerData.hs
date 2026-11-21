{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.PeerData
  ( Settings (settingsId, settingsPeers),
    declaredPeers,
    PeerDeclaration,
    pskPath,
    module IDR.Mesh.Identity,
    module IDR.Mesh.PublicKey,
    retirementKey,
    Advert (..),
    usableKeys,
    Peer (..),
    peerSlot,
    advertFor,
    Retirement (..),
    Snapshot (..),
    parseRegistration,
    parseSnapshot,
    parseScopedSnapshot,
    peerRetired,
    initiates,
    unique,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import IDR.Mesh.Etcd.Types (ClusterId, Revision)
import IDR.Mesh.IP (maxPublicAddresses, parseIP)
import IDR.Mesh.Identity
import IDR.Mesh.PSK.Secret (PskHash)
import IDR.Mesh.PublicKey
import System.FilePath (isAbsolute)

retirementKey :: MeshPrefix -> ServiceId -> InstanceId -> PublicKey -> Text
retirementKey prefix service ident key =
  servicePrefix prefix service <> "retirements/" <> instanceIdText ident <> "/" <> publicKeyHex key

data Settings = Settings {settingsId :: ServiceId, settingsPeers :: Map ServiceId PeerDeclaration}

instance FromJSON Settings where
  parseJSON = withObject "mesh service settings" $ \o -> Settings <$> o .: "id" <*> declaredPeers o

declaredPeers :: Object -> Parser (Map ServiceId PeerDeclaration)
declaredPeers o = o .: "peers"

-- A peer declaration still revokes the peer when its credential is unusable.
newtype PeerDeclaration = PeerDeclaration (Either String FilePath)

instance FromJSON PeerDeclaration where
  parseJSON value =
    pure . PeerDeclaration $ parseEither (withObject "mesh peer declaration" credential) value
    where
      credential o = do
        path <- o .: "psk"
        unless (isAbsolute path) $ fail "Expected an absolute mesh PSK path"
        pure path

pskPath :: (MonadFail m) => PeerDeclaration -> m FilePath
pskPath (PeerDeclaration path) = either fail pure path

-- The PSK an end wants for a peer service, and older keys it can still use
-- while a rotation is one-sided.
data Advert = Advert {wanted :: PskHash, held :: Set PskHash}
  deriving (Eq, Show)

instance ToJSON Advert where
  toJSON a = object (("pskHash" .= wanted a) : ["held" .= held a | not (Set.null (held a))])

instance FromJSON Advert where
  parseJSON = withObject "mesh PSK advert" $ \o ->
    Advert <$> o .: "pskHash" <*> o .:? "held" .!= Set.empty

usableKeys :: Advert -> Set PskHash
usableKeys a = Set.insert (wanted a) (held a)

data Peer = Peer
  { peerServiceId :: ServiceId,
    peerInstanceId :: InstanceId,
    peerAddress :: Text,
    peerPublicKey :: PublicKey,
    peerAddresses :: [Text],
    peerPort, peerHealthPort :: Int,
    peerAdverts :: Map ServiceId Advert,
    peerRevision :: Revision,
    peerPresent :: Bool
  }
  deriving (Eq, Show)

-- The registration slot a peer occupies.
peerSlot :: Peer -> (ServiceId, InstanceId)
peerSlot p = (peerServiceId p, peerInstanceId p)

-- A registration's advert for a peer service grants that service.
advertFor :: ServiceId -> Peer -> Maybe Advert
advertFor service = Map.lookup service . peerAdverts

instance ToJSON Peer where
  toJSON p =
    object
      [ "serviceId" .= peerServiceId p,
        "instanceId" .= peerInstanceId p,
        "address" .= peerAddress p,
        "publicKey" .= peerPublicKey p,
        "publicAddresses" .= peerAddresses p,
        "port" .= peerPort p,
        "healthPort" .= peerHealthPort p,
        "peers" .= peerAdverts p,
        "registrationRevision" .= peerRevision p,
        "registrationPresent" .= peerPresent p
      ]

data Retirement = Retirement
  { retirementServiceId :: ServiceId,
    retirementInstanceId :: InstanceId,
    retirementAddress :: Text,
    retirementPublicKey :: PublicKey,
    retirementRevision :: Revision
  }
  deriving (Eq, Show)

instance ToJSON Retirement where
  toJSON r =
    object
      [ "serviceId" .= retirementServiceId r,
        "instanceId" .= retirementInstanceId r,
        "address" .= retirementAddress r,
        "publicKey" .= retirementPublicKey r,
        "revision" .= retirementRevision r
      ]

-- The snapshot also keeps this workload's own registration as published, so
-- both ends of a connection decide from etcd state at one revision.
data Snapshot = Snapshot
  { snapCluster :: ClusterId,
    snapRevision :: Revision,
    snapSelf :: Maybe Peer,
    snapPeers :: [Peer],
    snapRetirements :: [Retirement]
  }
  deriving (Eq, Show)

-- Each grant needs a valid service ID and advert. A malformed grant revokes
-- that link while other peers continue to reconcile.
remoteAdverts :: Object -> Map ServiceId Advert
remoteAdverts o = case KM.lookup "peers" o of
  Just (Object entries) ->
    Map.fromList
      [ (service, advert)
      | (key, declaration) <- KM.toList entries,
        Right service <- [parseServiceId (Key.toText key)],
        Just advert <- [parseMaybe parseJSON declaration]
      ]
  _ -> Map.empty

parsePeer :: ServiceId -> InstanceId -> Text -> Revision -> Bool -> Object -> Parser Peer
parsePeer service ident address revision present o = do
  key <- o .: "publicKey"
  addresses <- o .: "publicAddresses" >>= traverse ipLiteral
  unless (length addresses <= maxPublicAddresses && unique addresses) $
    fail "Too many or duplicate public addresses in mesh peer registration"
  port <- o .: "port"
  health <- o .: "healthPort"
  unless (all (\n -> 1 <= n && n <= 65535) [port, health] && port /= health) $
    fail "Invalid mesh WireGuard or health port"
  pure (Peer service ident address key addresses port health (remoteAdverts o) revision present)
  where
    ipLiteral value = case parseIP (T.unpack value) of
      Just ip -> pure (T.pack (show ip))
      Nothing -> fail "Mesh peer public addresses must be IP literals"

parseRegistration :: MeshPrefix -> ServiceId -> InstanceId -> Revision -> Value -> Parser Peer
parseRegistration prefix service ident revision =
  withObject "mesh registration" (parsePeer service ident address revision True)
  where
    address = meshAddress prefix service ident

parseSnapshot :: MeshPrefix -> Value -> Parser Snapshot
parseSnapshot prefix = withObject "mesh peer snapshot" $ \o -> do
  cluster <- o .: "clusterId"
  revision <- o .: "revision"
  self <- o .:? "self" >>= traverse (cachedPeer revision)
  peers <- o .: "peers" >>= traverse (cachedPeer revision)
  unless (unique (map peerPublicKey peers) && unique (map peerAddress peers)) $
    fail "Duplicate public key or address in mesh peer snapshot"
  markers <- o .: "retirements" >>= traverse (cachedRetirement revision)
  let markerIdentity r = (retirementServiceId r, retirementInstanceId r, retirementPublicKey r)
  unless (unique (map markerIdentity markers)) $
    fail "Duplicate mesh retirement identity"
  pure (Snapshot cluster revision self peers markers)
  where
    identity o = do
      service <- o .: "serviceId"
      ident <- o .: "instanceId"
      address <- o .: "address"
      unless (address == meshAddress prefix service ident) $
        fail "Cached mesh address does not match its identity"
      pure (service, ident, address)
    observedAt revision field o = do
      observed <- o .: field
      unless (observed <= revision) $ fail "Cached entry is newer than its snapshot"
      pure observed
    cachedPeer revision = withObject "cached mesh peer" $ \o -> do
      (service, ident, address) <- identity o
      observed <- observedAt revision "registrationRevision" o
      present <- o .: "registrationPresent"
      parsePeer service ident address observed present o
    cachedRetirement revision = withObject "cached mesh retirement" $ \o -> do
      (service, ident, address) <- identity o
      Retirement service ident address <$> o .: "publicKey" <*> observedAt revision "revision" o

parseScopedSnapshot :: MeshPrefix -> PublicKey -> Value -> Parser (Maybe Snapshot)
parseScopedSnapshot prefix ownKey = withObject "mesh peer snapshot" $ \o -> do
  cachePrefix <- o .: "ipv6Prefix"
  cacheKey <- o .: "ownPublicKey"
  if cachePrefix == prefix && cacheKey == ownKey
    then do
      snapshot <- parseSnapshot prefix (Object o)
      unless (all ((== ownKey) . peerPublicKey) (snapSelf snapshot)) $
        fail "Cached own registration has another key"
      pure (Just snapshot)
    else pure Nothing

unique :: (Ord a) => [a] -> Bool
unique xs = length xs == Set.size (Set.fromList xs)

peerRetired :: [Retirement] -> Peer -> Bool
peerRetired markers p = any applies markers
  where
    applies r =
      retirementServiceId r == peerServiceId p
        && retirementInstanceId r == peerInstanceId p
        && retirementPublicKey r == peerPublicKey p
        && peerRevision p <= retirementRevision r

-- A host without advertised addresses cannot receive the first handshake, so it
-- initiates; otherwise the lower key does. A peer without addresses cannot be
-- reached first.
initiates :: Bool -> PublicKey -> Peer -> Bool
initiates acceptsInbound own peer =
  not (null (peerAddresses peer))
    && (not acceptsInbound || publicKeyBytes own < publicKeyBytes (peerPublicKey peer))
