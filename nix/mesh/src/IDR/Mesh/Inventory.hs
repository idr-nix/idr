{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- The host's enabled mesh services, keyed by their systemd unit names.
module IDR.Mesh.Inventory
  ( Inventory (..),
    Service (..),
    inventoryFile,
    readInventory,
    settingsFile,
  )
where

import Data.Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import GHC.Generics (Generic)
import IDR.Mesh.Common (readJson)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.PeerData (MeshPrefix, ServiceId)
import System.FilePath ((<.>), (</>))

newtype Inventory = Inventory {services :: Map FilePath Service}
  deriving (Generic)

-- A service, the prefix of the mesh it registers in, its declared peer
-- services in that mesh, and how many instances of each it uses at most.
data Service = Service
  { id :: ServiceId,
    ipv6Prefix :: MeshPrefix,
    peers :: Set.Set ServiceId,
    maxInstances :: Map ServiceId Int
  }
  deriving (Generic)

instance FromJSON Service where
  parseJSON = withObject "mesh service" $ \o ->
    Service <$> o .: "id" <*> o .: "ipv6Prefix" <*> o .: "peers" <*> o .:? "maxInstances" .!= Map.empty

instance FromJSON Inventory where
  parseJSON value = do
    inventory <- genericParseJSON defaultOptions value
    either fail (const (pure inventory)) (traverse NS.parseService (Map.keys (services inventory)))

inventoryFile :: FilePath
inventoryFile = "/etc/idr-mesh/services.json"

readInventory :: IO Inventory
readInventory = readJson inventoryFile

-- A workload's ID and declared peers, with the paths of their PSKs.
settingsFile :: String -> FilePath
settingsFile name = "/etc/idr-mesh/settings" </> name <.> "json"
