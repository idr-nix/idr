{-# LANGUAGE OverloadedStrings #-}

-- Each workload's DNS view lists the peers WireGuard has installed for it.
module IDR.Mesh.Dns (writeZone, validDnsAddress) where

import Control.Monad (unless, when)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import IDR.Mesh.Common
import IDR.Mesh.PeerData
import System.Directory (createDirectoryIfMissing)
import System.FilePath (isAbsolute, takeDirectory)
import System.Posix.Files (setFileMode)
import Text.Read (readMaybe)

validDnsAddress :: Text -> Bool
validDnsAddress address =
  let groups = T.splitOn ":" address
   in "fd" `T.isPrefixOf` address && length groups == 8 && all (lowerHex 4) groups

soaPrefix, soaSuffix :: Text
soaPrefix = "mesh. IN SOA ns.mesh. hostmaster.mesh. "
soaSuffix = " 30 30 3600 30"

renderZone :: Text -> [(ServiceId, Text)] -> Integer -> Text
renderZone nameserver records serial =
  T.unlines $
    [ "$ORIGIN mesh.",
      "$TTL 30",
      soaPrefix <> T.pack (show serial) <> soaSuffix,
      "mesh. IN NS ns.mesh.",
      "ns.mesh. IN AAAA " <> nameserver
    ]
      ++ [serviceIdText service <> ".mesh. IN AAAA " <> address | (service, address) <- records]

zoneSerial :: Text -> Either String Integer
zoneSerial content =
  case [digits | line <- T.lines content, Just digits <- [extract line]] of
    [digits] | Just n <- readMaybe (T.unpack digits), n >= 1 && n <= 4294967295 -> Right n
    _ -> Left "Mesh DNS zone must contain one generated SOA with a serial in [1, 4294967295]"
  where
    extract line = do
      body <- T.stripPrefix soaPrefix line
      digits <- T.stripSuffix soaSuffix body
      if T.null digits || T.any (\c -> c < '0' || c > '9') digits then Nothing else Just digits

-- Only the DNS readers group can enter the parent of the zone directories, so
-- the zone itself can be readable by everyone who gets there.
writeZone :: Text -> FilePath -> [(ServiceId, Text)] -> IO ()
writeZone nameserver output records = do
  unless (validDnsAddress nameserver) $ fail "Mesh DNS nameserver must be a full lowercase IPv6 ULA"
  unless (isAbsolute output) $ fail "Mesh DNS zone path must be absolute"
  createDirectoryIfMissing False (takeDirectory output)
  setFileMode (takeDirectory output) 0o755
  previous <- readOptionalFile output >>= traverse (either (fail . show) pure . TE.decodeUtf8')
  serial <- either fail pure $ maybe (Right 1) zoneSerial previous
  let render = renderZone nameserver (sort records)
      next
        | previous == Nothing || serial == 4294967295 = 1
        | otherwise = serial + 1
  when (previous /= Just (render serial)) $
    atomicWriteWithMode 0o644 output (TE.encodeUtf8 (render next))
