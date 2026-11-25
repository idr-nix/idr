{-# LANGUAGE OverloadedStrings #-}

-- Claiming and retiring registration slots in etcd. Every claim is journaled
-- before it is sent, so a lost response or a crash is resumed, not repeated.
module IDR.Mesh.Instance.Registry (Claim (..), claim, publishPending) where

import Control.Monad (forM_, guard, mfilter, void, when)
import Data.Aeson (decodeStrict', toJSON, withObject, (.:))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Effectful
import Effectful.Exception (onException, throwIO, trySync)
import IDR.Mesh.Common (describe, durableWrite, encodeState, logLine)
import IDR.Mesh.Duration (Seconds, secondsValue)
import IDR.Mesh.Etcd qualified as E
import IDR.Mesh.Etcd.Effect
import IDR.Mesh.Instance.Journal
import IDR.Mesh.PeerData qualified as Peer
import System.Random (randomRIO)

-- A claimed slot: the identity, its lease and the revision of the
-- registration it wrote.
data Claim = Claim {claimed :: Attempt, lease :: E.Lease, written :: E.Revision}

-- The key can be absent, occupied by another registrar, or still owned by us.
-- Compare the observed revision even when the public key matches.
data Ownership = Absent | Occupied E.Revision Bool

ownership :: Attempt -> Maybe E.Entry -> Ownership
ownership attempt = maybe Absent classify
  where
    classify e =
      let owner = decodeStrict' (E.entryValue e) >>= KM.lookup "publicKey"
       in Occupied (E.entryRevision e) (owner == Just (toJSON (publicKey attempt)))

unchanged :: Text -> Ownership -> E.Compare
unchanged key Absent = E.Missing key
unchanged key (Occupied rev _) = E.Modified key rev

unchangedEntry :: Text -> Maybe E.Entry -> E.Compare
unchangedEntry key = maybe (E.Missing key) (E.Modified key . E.entryRevision)

-- The registration slot and its retirement marker, read together.
slots :: Attempt -> E.Reads (Maybe E.Entry, Maybe E.Entry)
slots attempt = (,) <$> E.point (registrationKey attempt) <*> E.point (markerKey attempt)

registeredKey :: E.Entry -> Maybe Peer.PublicKey
registeredKey e =
  decodeStrict' (E.entryValue e)
    >>= parseMaybe (withObject "mesh registration" (.: "publicKey"))

-- Claims the saved instance ID, or a new random one when another registrar
-- holds it. The selection check runs once the lease exists, right before the
-- claim is sent.
claim ::
  (Etcd :> es, IOE :> es) =>
  Seconds ->
  FilePath ->
  FilePath ->
  (Peer.InstanceId -> Attempt) ->
  ByteString ->
  IO () ->
  Eff es Claim
claim leaseTTL journal idFile identity value checkSelection = do
  saved <- liftIO (savedInstanceId idFile)
  maybe allocate pure (mfilter (/= Peer.localInstance) saved) >>= tryClaim (128 :: Int)
  where
    allocate = liftIO $ do
      ident <- Peer.instanceIdFromWord32 <$> randomRIO (1, maxBound)
      durableWrite Nothing idFile (encodeState instanceIdVersion ident)
      pure ident

    tryClaim 0 _ = liftIO (fail "Could not register a mesh instance after 128 conflicts")
    tryClaim remaining ident = do
      let attempt = identity ident
          file = attemptFile journal attempt
      liftIO (readIntent file) >>= mapM_ (publishPending subsume file)
      (_, (current, retired)) <- readSnapshot (slots attempt)
      ours <- ownedByUs attempt current
      if not ours
        then allocate >>= tryClaim (remaining - 1)
        else do
          result <- write attempt (ownership attempt current) retired
          maybe (tryClaim (remaining - 1) ident) pure result

    -- After a reboot the slot can still hold this registrar's previous key
    -- until that lease expires. Its journal entry proves the slot is ours.
    ownedByUs attempt current = case ownership attempt current of
      Occupied _ False -> case current >>= registeredKey of
        Just owner -> liftIO (journaled attempt {publicKey = owner})
        Nothing -> pure False
      _ -> pure True
    journaled attempt = isJust <$> readIntent (attemptFile journal attempt)

    write attempt observed retired = do
      let key = registrationKey attempt
          marker = markerKey attempt
      cluster <- clusterId
      liftIO (remember journal cluster attempt)
      lease' <- grant (secondsValue leaseTTL)
      liftIO checkSelection `onException` revoke lease'
      result <-
        transaction
          [unchanged key observed, unchangedEntry marker retired]
          [E.Put key value (Just (E.leaseId lease')), E.Delete marker]
      case result of
        Just revision -> do
          -- The retirement lease held only the marker this claim deleted.
          forM_ (retired >>= E.entryLease) (void . trySync . revokeLease)
          pure (Just (Claim attempt lease' revision))
        Nothing -> do
          -- A failed comparison guarantees that nothing was attached.
          revoke lease'
          pure Nothing

-- Both the returning registrar and the retirement pass consume the same
-- durable intent under the workload's lock. A later selection cannot cancel
-- it. `within` opens the connection for the intent's cluster.
publishPending ::
  (IOE :> es) =>
  (Eff (Etcd : es) (Maybe E.Revision) -> Eff es (Maybe E.Revision)) ->
  FilePath ->
  Intent ->
  Eff es ()
publishPending within file intent = do
  retiring <- liftIO (retirementPending file)
  when retiring $ do
    published <- trySync . within $ do
      cluster <- clusterId
      if cluster == claimCluster intent
        then Just <$> retireAttempt (claimIdentity intent)
        else pure Nothing
    case published of
      -- Without access to the service, for example once its role is gone,
      -- the retirement is implicit: the registration expires with its lease
      -- and peers keep the instance as absent, as after a crash.
      Left err
        | E.permissionDenied err ->
            liftIO (logLine ("Retiring " ++ file ++ " without a marker: " ++ describe err))
        | otherwise -> throwIO err
      -- The endpoint now reaches another cluster, so the registration
      -- expires with its lease in the cluster it was claimed in.
      Right Nothing -> liftIO (logLine ("Retiring " ++ file ++ " without a marker: claimed in another etcd cluster"))
      Right (Just _) -> pure ()
    liftIO (completeRetirement file)

-- Connected hosts apply a marker within seconds. Its lease outlives every
-- tolerated etcd outage, then etcd deletes it. A host disconnected for longer
-- keeps the retired peer as absent until it reboots, like a peer that crashed
-- without retiring.
retentionSeconds :: Int64
retentionSeconds = 30 * 24 * 60 * 60

-- Re-registration supersedes the owner-specific marker.
retireAttempt :: (Etcd :> es, IOE :> es) => Attempt -> Eff es E.Revision
retireAttempt attempt = do
  let key = registrationKey attempt
      marker = markerKey attempt
  (_, (current, retired)) <- readSnapshot (slots attempt)
  let observed = ownership attempt current
      remove = [E.Delete key | Occupied _ True <- [observed]]
      -- Resume the original retirement revision after a lost response, even if
      -- a different key now owns the address.
      barrier = do
        entry <- retired
        guard (null remove && BS.null (E.entryValue entry))
        pure (E.entryRevision entry)
  case barrier of
    Just rev -> pure rev
    Nothing -> do
      lease' <- grant retentionSeconds
      written' <-
        trySync $
          transaction
            [unchanged key observed, unchangedEntry marker retired]
            (E.Put marker "" (Just (E.leaseId lease')) : remove)
      -- A transaction that otherwise throws may still have committed. Its
      -- lease then holds the marker, so only a failed comparison or a denied
      -- request releases it.
      case written' of
        Right (Just rev) -> pure rev
        Right Nothing -> revoke lease' >> liftIO (fail "Mesh registration changed during retirement")
        Left err -> do
          when (E.permissionDenied err) (revoke lease')
          throwIO err
