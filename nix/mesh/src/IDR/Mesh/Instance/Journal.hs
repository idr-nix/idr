{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Instance.Journal
  ( Attempt (..),
    registrationKey,
    markerKey,
    Intent (claimCluster, claimIdentity),
    attemptFile,
    readIntent,
    savedInstanceId,
    instanceIdVersion,
    retirementPending,
    markRetiring,
    completeRetirement,
    registrationFiles,
    remember,
    cleanupQueue,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson
import Data.List (isPrefixOf, sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Exception qualified as Eff
import GHC.Generics (Generic)
import IDR.Mesh.Common hiding (logLine)
import IDR.Mesh.Effects (Log, logFailure)
import IDR.Mesh.Etcd.Types (ClusterId)
import IDR.Mesh.PeerData qualified as Peer
import System.Directory
import System.FilePath

-- A durable intent to register, including when the transaction response was lost.
data Attempt = Attempt
  { meshPrefix :: Peer.MeshPrefix,
    serviceId :: Peer.ServiceId,
    instanceId :: Peer.InstanceId,
    publicKey :: Peer.PublicKey
  }
  deriving (Eq, Generic)

instance ToJSON Attempt

instance FromJSON Attempt

data Intent = Intent {claimCluster :: ClusterId, claimIdentity :: Attempt} deriving (Eq, Generic)

instance ToJSON Intent

instance FromJSON Intent

registrationKey :: Attempt -> Text
registrationKey a = Peer.instanceKey (meshPrefix a) (serviceId a) (instanceId a)

markerKey :: Attempt -> Text
markerKey a = Peer.retirementKey (meshPrefix a) (serviceId a) (instanceId a) (publicKey a)

-- Fixed-width IDs, hexadecimal public keys and validated mesh prefixes are safe basenames.
keyPrefix :: Attempt -> String
keyPrefix a =
  T.unpack (Peer.meshPrefixText (meshPrefix a) <> "-" <> Peer.publicKeyHex (publicKey a) <> "-")

attemptName :: Attempt -> FilePath
attemptName a = keyPrefix a ++ T.unpack (service <> instance') <.> "json"
  where
    service = Peer.serviceIdText (serviceId a)
    instance' = Peer.instanceIdText (instanceId a)

attemptFile :: FilePath -> Attempt -> FilePath
attemptFile dir attempt = dir </> attemptName attempt

-- State format versions, see `encodeState`.
intentVersion, instanceIdVersion :: Int
intentVersion = 1
instanceIdVersion = 1

readIntent :: FilePath -> IO (Maybe Intent)
readIntent file = do
  active <- readStateWith intentVersion named file
  maybe (readStateWith intentVersion named (retirementFile file)) (pure . Just) active
  where
    named value = do
      intent <- parseJSON value
      unless (takeFileName file == attemptName (claimIdentity intent)) $
        fail "registration intent of another file"
      pure intent

savedInstanceId :: FilePath -> IO (Maybe Peer.InstanceId)
savedInstanceId = readState instanceIdVersion

-- Renaming the intent keeps its cluster and identity together until the worker
-- finishes retiring that specific registration.
retirementFile :: FilePath -> FilePath
retirementFile file = file <.> "retiring"

retirementPending :: FilePath -> IO Bool
retirementPending = doesFileExist . retirementFile

markRetiring :: FilePath -> IO ()
markRetiring file = do
  pending <- retirementPending file
  unless pending (renameFile file (retirementFile file))
  syncPath (takeDirectory file)

completeRetirement :: FilePath -> IO ()
completeRetirement file = do
  removeIfExists (retirementFile file)
  syncPath (takeDirectory file)

remember :: FilePath -> ClusterId -> Attempt -> IO ()
remember dir cluster attempt = do
  createDirectoryIfMissing True dir
  let path = attemptFile dir attempt
      intent = Intent cluster attempt
  -- A claim in another cluster is abandoned; its lease expires there.
  old <- readIntent path
  unless (old == Just intent) (durableWrite Nothing path (encodeState intentVersion intent))
  -- Durably journal intent *before* sending the claim, even on a retry.
  syncPath path
  syncPath dir
  syncPath (takeDirectory dir)

registrationFiles :: FilePath -> IO [FilePath]
registrationFiles dir = do
  names <- listIfPresent dir
  let original name
        | takeExtension name == ".retiring" = dropExtension name
        | otherwise = name
      attempts = Set.fromList (filter ((== ".json") . takeExtension) (map original names))
  pure (map (dir </>) (Set.toAscList attempts))

-- Prioritize a renamed service using the same public key in the same mesh.
-- Corrupt or temporarily inaccessible attempts remain queued for retry.
cleanupQueue ::
  (Log :> es, IOE :> es) =>
  FilePath ->
  Attempt ->
  (FilePath -> Eff es ()) ->
  Eff es ()
cleanupQueue dir active retire = discover
  where
    discover = do
      result <- Eff.trySync (liftIO (registrationFiles dir))
      case result of
        Left err -> do
          logFailure "Could not inspect mesh registrations" err
          pause >> discover
        Right files -> drain (sortOn later (filter (not . isActive) files))

    isActive file = takeFileName file == attemptName active
    later file = not (keyPrefix active `isPrefixOf` takeFileName file)

    drain [] = pure ()
    drain (file : rest) = do
      result <- Eff.trySync (retire file)
      next <- case result of
        Right () -> pure rest
        Left err -> do
          logFailure ("Could not retire mesh registration " ++ file) err
          pure (rest ++ [file])
      unless (null next) (pause >> drain next)

    pause = liftIO (threadDelay 5000000)
