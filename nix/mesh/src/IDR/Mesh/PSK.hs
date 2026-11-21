{-# LANGUAGE OverloadedStrings #-}

-- A connection's PSK follows from the two registrations. Each end advertises
-- the key it wants and the older keys it still holds, and both ends install the
-- same agreed key. Older keys stay in a local store only while some instance of
-- the peer service still agrees on them.
module IDR.Mesh.PSK (agreed, Keys (..), Unreadable (..), syncKeys, target) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import IDR.Mesh.Common (encodeState, readState, removeIfExists, trySync)
import IDR.Mesh.Desired qualified as D
import IDR.Mesh.PSK.Secret (PskHash, Secret, readSecret, secretHash)
import IDR.Mesh.PeerData
import MAlonzo.Code.IDR.Mesh.Foreign qualified as Kernel
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath (dropExtension, takeExtension, (<.>), (</>))
import System.Posix.Files (setFileMode)

-- Both ends evaluate this on the same two registrations. The Agda kernel
-- (Agreement.agda) proves both ends get the same result and that the result
-- is a key both ends can install.
agreed :: (PublicKey, Advert) -> (PublicKey, Advert) -> Maybe PskHash
agreed (kx, x) (ky, y) =
  Kernel.agreed () () before (==) kx (wanted x) (ascending x) ky (wanted y) (ascending y)
  where
    before a b = publicKeyBytes a < publicKeyBytes b
    ascending = Set.toAscList . usableKeys

-- The configured key first, then older keys that are still advertised or
-- still published.
data Keys = Keys {advert :: Advert, secrets :: NonEmpty Secret}

-- An older key is advertised while it is the agreed key for a known instance
-- of the peer service, and is deleted only once the published registration no
-- longer lists it. Without a published registration or a known instance,
-- every stored key is kept. A peer service without a usable credential gets
-- no advert, which revokes that link. Also returns the store files whose kept
-- keys changed; the caller writes them.
syncKeys ::
  Unreadable ->
  FilePath ->
  Map ServiceId PeerDeclaration ->
  Maybe D.Desired ->
  IO (Map ServiceId Keys, [(FilePath, ByteString)])
syncKeys unreadable dir declared desired = do
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  removeUndeclared dir declared
  synced <- Map.traverseMaybeWithKey sync declared
  pure (fmap fst synced, concatMap snd (Map.elems synced))
  where
    sync service declaration = do
      let file = dir </> T.unpack (serviceIdText service) <.> "json"
      stored <- fromMaybe [] <$> readState keyStoreVersion file
      configured <- trySync (pskPath declaration >>= readSecret)
      case (configured, stored, unreadable) of
        (Right key, _, _) -> pure (Just (store file service key stored))
        -- The stored list starts with the last configured key.
        (Left _, key : _, KeepLast) -> pure (Just (store file service key stored))
        _ -> Nothing <$ removeIfExists file
    store file service key stored =
      let result = keepNeeded desired service key stored
          kept = toList (secrets result)
          changed = map secretHash kept /= map secretHash stored
       in (result, [(file, encodeState keyStoreVersion kept) | changed])

-- See `encodeState`.
keyStoreVersion :: Int
keyStoreVersion = 1

-- What a credential that cannot be read means.
data Unreadable
  = -- `ctl apply` runs after a credential change has settled, so the link is
    -- revoked and its stored keys are forgotten.
    Revoke
  | -- Up and the agent's requests can run while a secret is missing or being
    -- replaced, so the last readable key stays.
    KeepLast

-- Deletes the stores of services that are no longer declared.
removeUndeclared :: FilePath -> Map ServiceId PeerDeclaration -> IO ()
removeUndeclared dir declared = do
  stores <- listDirectory dir
  forM_ stores $ \name -> case parseServiceId (T.pack (dropExtension name)) of
    Right service
      | takeExtension name == ".json" && Map.notMember service declared ->
          removeIfExists (dir </> name)
    _ -> pure ()

-- The configured key and the stored keys that are still needed or published.
keepNeeded :: Maybe D.Desired -> ServiceId -> Secret -> [Secret] -> Keys
keepNeeded desired service key stored = Keys (Advert (secretHash key) held) kept
  where
    others = filter ((/= secretHash key) . secretHash) stored
    published = desired >>= Map.lookup service . D.published
    instances = [p | p <- foldMap D.peers desired, D.service p == service]
    agreedWith k p = D.agreed p == Just (secretHash k)
    needed k = isNothing published || null instances || any (agreedWith k) instances
    stillPublished k = any (Set.member (secretHash k) . usableKeys) published
    held = Set.fromList (map secretHash (filter needed others))
    kept = key :| filter (\k -> needed k || stillPublished k) others

-- The key to install for a peer. A new peer gets the agreed key, or the wanted
-- key when there is none. An installed key changes only to the agreed key, and
-- only while both registrations are present, so a peer that is cut off from
-- etcd keeps the key it has.
target :: Maybe PskHash -> Bool -> Advert -> Maybe PskHash -> PskHash
target installed present mine agreement = case (installed, agreement) of
  (Nothing, _) -> fromMaybe (wanted mine) agreement
  (Just current, Just k) | present -> k | otherwise -> current
  (Just current, Nothing) -> current
