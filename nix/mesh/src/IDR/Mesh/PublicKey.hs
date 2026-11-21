{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.PublicKey
  ( PublicKey,
    parsePublicKey,
    publicKeyFromHex,
    publicKeyText,
    publicKeyBytes,
    publicKeyHex,
    canonicalKeyBytes,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.ByteArray.Encoding (Base (Base16), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text.Encoding qualified as T
import IDR.Mesh.Identity (lowerHex)

-- Keep the deployed base64 ordering for maps, cursors and persisted lists.
data PublicKey = PublicKey Text ByteString deriving (Eq, Ord)

instance Show PublicKey where
  showsPrec d = showsPrec d . publicKeyText

publicKeyText :: PublicKey -> Text
publicKeyText (PublicKey t _) = t

publicKeyBytes :: PublicKey -> ByteString
publicKeyBytes (PublicKey _ b) = b

publicKeyHex :: PublicKey -> Text
publicKeyHex = T.decodeUtf8 . convertToBase Base16 . publicKeyBytes

checkedBytes :: Either String ByteString -> Either String ByteString
checkedBytes (Right b) | BS.length b == 32 && BS.any (/= 0) b = Right b
checkedBytes _ = Left "Invalid WireGuard key"

-- base64-bytestring's strict decoder checks the padding and unused bits.
canonicalKeyBytes :: Text -> Either String ByteString
canonicalKeyBytes = checkedBytes . Base64.decode . T.encodeUtf8

parsePublicKey :: Text -> Either String PublicKey
parsePublicKey t = PublicKey t <$> canonicalKeyBytes t

publicKeyFromHex :: Text -> Either String PublicKey
publicKeyFromHex t = do
  unless (lowerHex 64 t) (Left "Invalid retired mesh public key")
  b <- checkedBytes (convertFromBase Base16 (T.encodeUtf8 t))
  pure (PublicKey (T.decodeUtf8 (Base64.encode b)) b)

instance FromJSON PublicKey where
  parseJSON = withText "WireGuard public key" (either fail pure . parsePublicKey)

instance ToJSON PublicKey where
  toJSON = toJSON . publicKeyText
  toEncoding = toEncoding . publicKeyText
