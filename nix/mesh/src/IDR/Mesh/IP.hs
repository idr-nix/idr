{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.IP (Host (..), parseHost, parseIP, numericHostIP, maxPublicAddresses) where

import Control.Applicative ((<|>))
import Control.Monad (guard)
import Data.Char (isAlphaNum, isAscii, isControl, isDigit, isHexDigit, isSpace)
import Data.IP (IP (IPv6))
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Network.URI (isIPv4address, isIPv6address)
import Text.Read (readMaybe)

data Host = DNS String | Address IP deriving (Eq)

-- Bounds each registration and the health probes sent to one peer.
maxPublicAddresses :: Int
maxPublicAddresses = 129

-- NSS accepts abbreviated, hexadecimal and octal IPv4 addresses. A failed
-- numeric parse must not send an etcd credential to such a reinterpretation.
parseHost :: String -> Maybe Host
parseHost name =
  (Address <$> parseIP name) <|> do
    let domain = T.toLower (T.pack name)
        bare = fromMaybe domain (T.stripSuffix "." domain)
        labels = T.splitOn "." bare
        valid label = case (T.uncons label, T.unsnoc label) of
          (Just (first, _), Just (_, lastChar)) ->
            isAlphaNum first
              && isAlphaNum lastChar
              && T.length label <= 63
              && T.all (\c -> isAlphaNum c || c == '-') label
          _ -> False
        numeric label =
          T.all isDigit label || maybe False (T.all isHexDigit) (T.stripPrefix "0x" label)
    guard (all isAscii name && T.length bare <= 253 && all valid labels && not (all numeric labels))
    pure (DNS (T.unpack bare))

-- iproute converts some malformed groups to zero. Check the literal syntax
-- first, including decimal octets in the dotted tail of an IPv6 address.
parseIP :: String -> Maybe IP
parseIP input = do
  guard (isIPv4address input || isIPv6address input)
  let lastGroup = T.takeWhileEnd (/= ':') (T.pack input)
      canonical octet = octet == "0" || not ("0" `T.isPrefixOf` octet)
  guard (not (T.any (== '.') lastGroup) || all canonical (T.splitOn "." lastGroup))
  readMaybe input

-- A socket dial can name the local interface after a numeric IPv6 address.
numericHostIP :: String -> Maybe IP
numericHostIP host = case break (== '%') host of
  (addr, '%' : zone) -> do
    ip@(IPv6 _) <- parseIP addr
    guard (not (null zone) && all valid zone)
    pure ip
  _ -> parseIP host
  where
    valid c = isAscii c && not (isControl c || isSpace c || c `elem` ("/:" :: String))
