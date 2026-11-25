{-# LANGUAGE OverloadedStrings #-}

-- Each workload's DNS view lists the peers WireGuard has installed for it, by
-- service ID below mesh, and the names it resolves to them.
module IDR.Mesh.Dns (writeZone, writeNames, writeRouted, validDnsAddress) where

import Control.Monad (unless, when)
import Data.Set qualified as Set
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

soaPrefix :: Text -> Text
soaPrefix origin = origin <> " IN SOA ns.mesh. hostmaster.mesh. "

soaSuffix :: Text
soaSuffix = " 30 30 3600 30"

renderZone :: Text -> Text -> [(Text, Text)] -> Integer -> Text
renderZone origin nameserver records serial =
  T.unlines $
    [ "$ORIGIN " <> origin,
      "$TTL 30",
      soaPrefix origin <> T.pack (show serial) <> soaSuffix,
      origin <> " IN NS " <> host,
      host <> " IN AAAA " <> nameserver
    ]
      ++ [name <> " IN AAAA " <> address | (name, address) <- records]
  where
    -- The nameserver's name lies in the zone.
    host = if origin == "." then "ns.mesh." else "ns." <> origin

zoneSerial :: Text -> Text -> Either String Integer
zoneSerial origin content =
  case [digits | line <- T.lines content, Just digits <- [extract line]] of
    [digits] | Just n <- readMaybe (T.unpack digits), n >= 1 && n <= 4294967295 -> Right n
    _ -> Left "Mesh DNS zone must contain one generated SOA with a serial in [1, 4294967295]"
  where
    extract line = do
      body <- T.stripPrefix (soaPrefix origin) line
      digits <- T.stripSuffix soaSuffix body
      if T.null digits || T.any (\c -> c < '0' || c > '9') digits then Nothing else Just digits

-- Only the DNS readers group can enter the parent of the zone directories, so
-- the zone itself can be readable by everyone who gets there.
writeZoneFile :: Text -> Text -> FilePath -> [(Text, Text)] -> IO ()
writeZoneFile origin nameserver output records = do
  unless (validDnsAddress nameserver) $ fail "Mesh DNS nameserver must be a full lowercase IPv6 ULA"
  unless (isAbsolute output) $ fail "Mesh DNS zone path must be absolute"
  createDirectoryIfMissing False (takeDirectory output)
  setFileMode (takeDirectory output) 0o755
  previous <- readOptionalFile output >>= traverse (either (fail . show) pure . TE.decodeUtf8')
  serial <- either fail pure $ maybe (Right 1) (zoneSerial origin) previous
  let render = renderZone origin nameserver (Set.toList (Set.fromList records))
      next
        | previous == Nothing || serial == 4294967295 = 1
        | otherwise = serial + 1
  when (previous /= Just (render serial)) $
    atomicWriteWithMode 0o644 output (TE.encodeUtf8 (render next))

writeZone :: Text -> FilePath -> [(ServiceId, Text)] -> IO ()
writeZone nameserver output records =
  writeZoneFile "mesh." nameserver output [(serviceIdText service <> ".mesh.", address) | (service, address) <- records]

-- The names the workload resolves to its installed peers, each with a peer's
-- mesh address.
writeNames :: Text -> FilePath -> [(Text, Text)] -> IO ()
writeNames nameserver output records =
  writeZoneFile "." nameserver output [(name <> ".", address) | (name, address) <- records]

-- The instances of a peer service that a linked workload forwards, in the
-- zone of the service's name in a view that reaches it through that workload.
writeRouted :: Text -> FilePath -> ServiceId -> [Text] -> IO ()
writeRouted nameserver output service addresses =
  writeZoneFile origin nameserver output [(origin, address) | address <- addresses]
  where
    origin = serviceIdText service <> ".mesh."
