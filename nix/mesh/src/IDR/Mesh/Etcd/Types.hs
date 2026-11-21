{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module IDR.Mesh.Etcd.Types
  ( ClusterId (..),
    Revision,
    toRevision,
    revisionNumber,
    nextRevision,
    LeaseId,
    leaseFromWire,
    leaseNumber,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Int (Int64)
import Data.Word (Word64)

newtype ClusterId = ClusterId Word64
  deriving stock (Eq, Ord)
  deriving newtype (Show, FromJSON, ToJSON)

-- | An actual MVCC revision. Zero on the wire requests the latest state.
newtype Revision = Revision Int64
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

revisionNumber :: Revision -> Int64
revisionNumber (Revision n) = n

toRevision :: (MonadFail m) => Int64 -> m Revision
toRevision n
  | n > 0 = pure (Revision n)
  | otherwise = fail "An etcd revision must be positive"

instance FromJSON Revision where
  parseJSON value = parseJSON value >>= toRevision

nextRevision :: (MonadFail m) => Revision -> m Revision
nextRevision (Revision n)
  | n == maxBound = fail "No revision follows the maximum etcd revision"
  | otherwise = pure (Revision (n + 1))

-- | Lease IDs are signed and nonzero. The protobuf zero denotes a
-- persistent key and is represented by Nothing at call sites.
newtype LeaseId = LeaseId Int64
  deriving stock (Eq, Show)

leaseNumber :: LeaseId -> Int64
leaseNumber (LeaseId n) = n

leaseFromWire :: Int64 -> Maybe LeaseId
leaseFromWire 0 = Nothing
leaseFromWire n = Just (LeaseId n)
