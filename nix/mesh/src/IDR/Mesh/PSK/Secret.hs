{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.PSK.Secret (PskHash, Secret, parseSecret, readSecret, secretKey, secretHash) where

import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import IDR.Mesh.Common (readRegularFile)
import IDR.Mesh.Identity (lowerHex)
import IDR.Mesh.PublicKey (canonicalKeyBytes)

newtype PskHash = PskHash Text
  deriving newtype (Eq, Ord, Show, ToJSON)

instance FromJSON PskHash where
  parseJSON = withText "PSK fingerprint" $ \h ->
    PskHash h <$ unless (lowerHex 64 h) (fail "Invalid PSK fingerprint")

-- Only the key parser can pair canonical WireGuard text with its fingerprint.
-- Keep secret material out of diagnostics.
data Secret = Secret Text PskHash deriving (Eq)

parseSecret :: Text -> Either String Secret
parseSecret key = Secret key . fingerprint <$> canonicalKeyBytes key

fingerprint :: ByteString -> PskHash
fingerprint bytes = PskHash (T.pack (show (hash bytes :: Digest SHA256)))

secretKey :: Secret -> Text
secretKey (Secret key _) = key

secretHash :: Secret -> PskHash
secretHash (Secret _ h) = h

readSecret :: FilePath -> IO Secret
readSecret path = do
  raw <- readRegularFile path
  key <- either (const (fail "Invalid WireGuard preshared key encoding")) pure (TE.decodeUtf8' raw)
  either fail pure (parseSecret (T.stripEnd key))

instance ToJSON Secret where
  toJSON k = object ["key" .= secretKey k, "hash" .= secretHash k]

instance FromJSON Secret where
  parseJSON = withObject "stored PSK" $ \o -> do
    -- Both fields are required, so two fields leave room for nothing else.
    unless (KM.size o == 2) (fail "Unexpected fields in stored PSK")
    key <- o .: "key" >>= either fail pure . parseSecret
    expected <- o .: "hash"
    unless (secretHash key == expected) (fail "Stored PSK fingerprint differs")
    pure key
