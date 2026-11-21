{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.PSK.Keys (keys) where

import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Curve25519 qualified as Curve
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.), (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.Char (isSpace)
import IDR.Mesh.Common (atomicWritePrivate, readOptionalFile)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- The key pair lives only in /run, so each boot gets a new one.
keys :: FilePath -> IO ()
keys dir = do
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  let privateFile = dir </> "private-key"
  private <- readOptionalFile privateFile
  raw <- case private of
    Just encoded -> case B64.decode (BC.dropWhileEnd isSpace encoded) of
      Right bytes | BS.length bytes == 32 -> pure bytes
      _ -> fail "Invalid WireGuard private key"
    Nothing -> do
      seed <- getRandomBytes 32
      let bytes =
            BS.cons (BS.head seed .&. 248) (BS.take 30 (BS.tail seed))
              `BS.snoc` ((BS.last seed .&. 127) .|. 64)
      atomicWritePrivate privateFile (B64.encode bytes <> "\n")
      pure bytes
  case Curve.secretKey raw of
    CryptoPassed k ->
      atomicWritePrivate (dir </> "public-key") (B64.encode (BA.convert (Curve.toPublic k)) <> "\n")
    CryptoFailed _ -> fail "Invalid WireGuard private key"
