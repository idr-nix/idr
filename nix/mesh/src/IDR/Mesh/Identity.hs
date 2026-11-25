{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Canonical identifiers used in mesh declarations, registrations and addresses.
-- The constructors stay private so an ID can be interpolated into an etcd path
-- or IPv6 address without rechecking its length and alphabet.
module IDR.Mesh.Identity
  ( MeshPrefix,
    parseMeshPrefix,
    meshPrefixText,
    ServiceId,
    InstanceId,
    parseServiceId,
    parseInstanceId,
    instanceIdFromWord32,
    localInstance,
    serviceIdText,
    instanceIdText,
    lowerHex,
    servicePrefix,
    instanceKey,
    meshAddress,
  )
where

import Data.Aeson
  ( FromJSON (..),
    FromJSONKey (..),
    FromJSONKeyFunction (..),
    ToJSON,
    ToJSONKey,
    withText,
  )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Numeric (showHex)

-- The deployed keyspace uses three fully written lowercase hextets.
newtype MeshPrefix = MeshPrefix Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseMeshPrefix :: Text -> Either String MeshPrefix
parseMeshPrefix raw = case T.splitOn ":" raw of
  [a, b, c] | "fd" `T.isPrefixOf` a && all (lowerHex 4) [a, b, c] -> Right (MeshPrefix raw)
  _ -> Left "Invalid mesh IPv6 prefix"

meshPrefixText :: MeshPrefix -> Text
meshPrefixText (MeshPrefix t) = t

instance FromJSON MeshPrefix where
  parseJSON = withText "mesh prefix" (either fail pure . parseMeshPrefix)

newtype ServiceId = ServiceId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, ToJSONKey)

newtype InstanceId = InstanceId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

lowerHex :: Int -> Text -> Bool
lowerHex width s = T.length s == width && T.all hexadecimal s
  where
    hexadecimal c = ('0' <= c && c <= '9') || ('a' <= c && c <= 'f')

parseServiceId :: Text -> Either String ServiceId
parseServiceId t
  | lowerHex 12 t = Right (ServiceId t)
  | otherwise = Left "Mesh service ID must be twelve lowercase hexadecimal digits"

parseInstanceId :: Text -> Either String InstanceId
parseInstanceId t
  | lowerHex 8 t = Right (InstanceId t)
  | otherwise = Left "Mesh instance ID must be eight lowercase hexadecimal digits"

instanceIdFromWord32 :: Word32 -> InstanceId
instanceIdFromWord32 n = InstanceId (T.justifyRight 8 '0' (T.pack (showHex n "")))

-- The instance ID that a service has on the links to peers on its own machine.
-- No registration claims it.
localInstance :: InstanceId
localInstance = instanceIdFromWord32 0

serviceIdText :: ServiceId -> Text
serviceIdText (ServiceId t) = t

instanceIdText :: InstanceId -> Text
instanceIdText (InstanceId t) = t

instance FromJSON ServiceId where
  parseJSON = withText "mesh service ID" (either fail pure . parseServiceId)

instance FromJSONKey ServiceId where
  fromJSONKey = FromJSONKeyTextParser (either fail pure . parseServiceId)

instance FromJSON InstanceId where
  parseJSON = withText "mesh instance ID" (either fail pure . parseInstanceId)

servicePrefix :: MeshPrefix -> ServiceId -> Text
servicePrefix prefix service =
  "/idr/mesh/" <> meshPrefixText prefix <> "/services/" <> serviceIdText service <> "/"

instanceKey :: MeshPrefix -> ServiceId -> InstanceId -> Text
instanceKey prefix service ident =
  servicePrefix prefix service <> "instances/" <> instanceIdText ident

meshAddress :: MeshPrefix -> ServiceId -> InstanceId -> Text
meshAddress prefix service ident =
  T.intercalate ":" (meshPrefixText prefix : T.chunksOf 4 suffix)
  where
    suffix = serviceIdText service <> instanceIdText ident
