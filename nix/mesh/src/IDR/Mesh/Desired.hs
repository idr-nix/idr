{-# LANGUAGE DeriveGeneric #-}

-- What the agent wants installed for one workload. The agent derives it from
-- discovery, health and the host's addresses. netd validates it, derives each
-- peer's address itself and chooses every secret from its own key store.
module IDR.Mesh.Desired (Desired (..), Peer (..), Endpoint (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)
import IDR.Mesh.Etcd.Types (Revision)
import IDR.Mesh.Identity (InstanceId, ServiceId)
import IDR.Mesh.PSK.Secret (PskHash)
import IDR.Mesh.PeerData (Advert)
import IDR.Mesh.PublicKey (PublicKey)

data Desired = Desired
  { -- The discovery snapshot this state derives from.
    revision :: Revision,
    -- This workload's adverts as its registration last appeared in etcd.
    published :: Map ServiceId Advert,
    peers :: [Peer]
  }
  deriving (Eq, Generic)

instance ToJSON Desired

instance FromJSON Desired

-- Every instance of a declared peer service that discovery keeps.
data Peer = Peer
  { service :: ServiceId,
    instanceId :: InstanceId,
    publicKey :: PublicKey,
    -- The peer's registration grants this workload's service.
    accepts :: Bool,
    -- The PSK both adverts agree on.
    agreed :: Maybe PskHash,
    -- Both registrations are in etcd, so both ends see the same agreement.
    present :: Bool,
    -- Set when this end initiates: the peer's first healthy address.
    endpoint :: Maybe Endpoint
  }
  deriving (Eq, Generic)

instance ToJSON Peer

instance FromJSON Peer

data Endpoint = Endpoint {host :: Text, port :: Int}
  deriving (Eq, Generic)

instance ToJSON Endpoint

instance FromJSON Endpoint
