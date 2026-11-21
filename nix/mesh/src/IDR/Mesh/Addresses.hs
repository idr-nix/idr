{-# LANGUAGE OverloadedStrings #-}

-- The host's transport state: the addresses it advertises to peers, the
-- addresses it can send from, and the routing that chooses between them.
module IDR.Mesh.Addresses
  ( HostAddresses (..),
    addressesFile,
    addressesVersion,
    collect,
    advertised,
    transportChanged,
    parseAddress,
  )
where

import Control.Monad (filterM)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits (shiftR, (.&.))
import Data.Containers.ListUtils (nubOrdOn)
import Data.IP
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import IDR.Mesh.Common (readProcessJson)
import IDR.Mesh.IP (maxPublicAddresses, parseIP)
import Numeric (showHex)

-- Snapshot ---------------------------------------------------------------

addressesFile :: FilePath
addressesFile = "/run/idr-mesh-addresses/addresses.json"

-- See `encodeState`.
addressesVersion :: Int
addressesVersion = 1

data HostAddresses = HostAddresses
  { -- The configured addresses, or else the stable public addresses of
    -- active interfaces, IPv6 first.
    publicAddresses :: [IP],
    -- Every usable address of an active interface, IPv6 first.
    localAddresses :: [IP],
    -- Everything that can change the kernel's choice of source address. It is
    -- only ever compared, never interpreted.
    routing :: Value
  }
  deriving (Eq)

instance ToJSON HostAddresses where
  toJSON h =
    object
      [ "publicAddresses" .= map renderAddress (publicAddresses h),
        "localAddresses" .= map renderAddress (localAddresses h),
        "routing" .= routing h
      ]

instance FromJSON HostAddresses where
  parseJSON = withObject "host addresses" $ \o ->
    HostAddresses
      <$> (o .: "publicAddresses" >>= addresses)
      <*> (o .: "localAddresses" >>= addresses)
      <*> o .: "routing"
    where
      addresses = traverse (either fail pure . parseAddress)

collect :: [IP] -> IO HostAddresses
collect configured = do
  links <- ipJson ["address", "show"]
  assigned <- concat <$> either fail pure (traverse (parseEither linkAddresses) links)
  let -- Temporary addresses rotate and deprecated ones are expiring. Duplicate
      -- address detection is per interface, so another interface can still
      -- receive traffic for an address that failed it here.
      unstable = ["tentative", "dadfailed", "temporary", "deprecated"]
      stable a = public (local a) && all (`notElem` flags a) unstable
      discovered = byFamily (map local (filter stable assigned))
      chosen = if null configured then discovered else nubOrdOn familyKey configured
  HostAddresses (take maxPublicAddresses chosen) (byFamily (map local assigned))
    <$> routingFingerprint assigned

-- The advertised addresses as registrations publish them.
advertised :: HostAddresses -> [Text]
advertised = map (T.pack . renderAddress) . publicAddresses

-- Re-applying sets each endpoint again, so WireGuard re-selects its source
-- after a local address or route change. Which end initiates can also change,
-- even while the etcd watch is offline.
transportChanged :: Maybe HostAddresses -> HostAddresses -> Bool
transportChanged previous current = fmap transport previous /= Just (transport current)
  where
    transport h = (localAddresses h, routing h, null (publicAddresses h))

-- Reading `ip -json` -------------------------------------------------------

ipJson :: [String] -> IO [Value]
ipJson args = readProcessJson "ip" (["-json", "-N"] ++ args)

-- An IPv4 or IPv6 address of an interface.
data HostAddress = HostAddress
  { interface :: Int,
    local :: IP,
    prefixLength :: Int,
    scope :: Text,
    flags :: [Text]
  }

-- The boolean address flags iproute2 reports, by name.
addressFlags :: [Text]
addressFlags = ["deprecated", "tentative", "dadfailed", "optimistic", "temporary", "home"]

-- The usable addresses of one interface from `ip -json address show`, if the
-- interface is up and has carrier. iproute2 adds NO-CARRIER when IFF_UP is set
-- and IFF_RUNNING is clear.
linkAddresses :: Value -> Parser [HostAddress]
linkAddresses = withObject "ip link" $ \link -> do
  linkFlags <- link .: "flags" :: Parser [Text]
  if "UP" `elem` linkFlags && "NO-CARRIER" `notElem` linkFlags
    then do
      index <- link .: "ifindex"
      entries <- link .:? "addr_info" .!= []
      filter (usable . local) . catMaybes <$> traverse (address index) entries
    else pure []
  where
    address index = withObject "ip address" $ \entry -> do
      family <- entry .:? "family" :: Parser (Maybe Text)
      if family `elem` [Just "inet", Just "inet6"]
        then do
          ip <- entry .: "local" >>= either fail pure . parseAddress
          set <- filterM (\flag -> entry .:? Key.fromText flag .!= False) addressFlags
          Just <$> (HostAddress index ip <$> entry .: "prefixlen" <*> entry .: "scope" <*> pure set)
        else pure Nothing

-- IPv6 source address properties, routes, rules and nexthops. Fields that
-- change by themselves between dumps are removed, and routes in the local
-- table only mirror the host's addresses.
routingFingerprint :: [HostAddress] -> IO Value
routingFingerprint assigned = do
  ipv4Routes <- routes "-4"
  ipv6Routes <- routes "-6"
  ipv4Rules <- ipJson ["-4", "rule", "show"]
  ipv6Rules <- ipJson ["-6", "rule", "show"]
  nexthops <- ipJson ["nexthop", "show"]
  pure . withoutVolatile $
    object
      [ "ipv6Sources" .= sources,
        "ipv4Routes" .= ipv4Routes,
        "ipv6Routes" .= ipv6Routes,
        "ipv4Rules" .= ipv4Rules,
        "ipv6Rules" .= ipv6Rules,
        "nexthops" .= nexthops
      ]
  where
    -- Linux may choose another source when an address becomes deprecated.
    -- Lifetimes count down between dumps; the flags change at expiry.
    sources =
      [ object
          [ "ifindex" .= interface a,
            "address" .= renderAddress (local a),
            "prefixlen" .= prefixLength a,
            "scope" .= scope a,
            "flags" .= flags a
          ]
      | a <- sortOn (\a -> (interface a, local a)) assigned,
        IPv6 _ <- [local a]
      ]
    routes family =
      filter (not . localDelivery) <$> ipJson [family, "route", "show", "table", "all"]

-- Local, broadcast, anycast and multicast routes in the local table (255).
localDelivery :: Value -> Bool
localDelivery (Object route) = field "table" 255 && any (field "type") [2 .. 5]
  where
    field :: Key -> Int -> Bool
    field key n = KeyMap.lookup key route `elem` [Just (toJSON n), Just (toJSON (show n))]
localDelivery _ = False

withoutVolatile :: Value -> Value
withoutVolatile (Object fields) =
  Object (fmap withoutVolatile (foldr KeyMap.delete fields volatile))
  where
    volatile = ["expires", "error", "ipid", "ts", "tsage", "unbalanced_time"]
withoutVolatile (Array values) = Array (fmap withoutVolatile values)
withoutVolatile value = value

-- Address classes ----------------------------------------------------------

-- Not unspecified, broadcast, loopback or multicast.
usable :: IP -> Bool
usable (IPv4 a) =
  a `notElem` ["0.0.0.0", "255.255.255.255"] && not (inAny a ["127.0.0.0/8", "224.0.0.0/4"])
usable (IPv6 a) = a `notElem` ["::", "::1"] && not (a `isMatchedTo` "ff00::/8")

-- Globally reachable, per the IANA special-purpose address registries.
public :: IP -> Bool
public (IPv4 a) = a `elem` globalIPv4 || not (inAny a specialIPv4)
public (IPv6 a)
  | a `isMatchedTo` "64:ff9b::/96" = True
  | a `isMatchedTo` "2001::/23" = a `elem` globalIPv6 || inAny a globalIPv6Ranges
  | otherwise = a `isMatchedTo` "2000::/3" && not (inAny a specialIPv6)

inAny :: (Addr a) => a -> [AddrRange a] -> Bool
inAny a = any (isMatchedTo a)

-- IPv4 special-purpose ranges that are not globally reachable.
specialIPv4 :: [AddrRange IPv4]
specialIPv4 =
  [ "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/3"
  ]

-- Globally reachable exceptions inside 192.0.0.0/24.
globalIPv4 :: [IPv4]
globalIPv4 = ["192.0.0.9", "192.0.0.10"]

-- Globally reachable addresses and ranges inside 2001::/23.
globalIPv6 :: [IPv6]
globalIPv6 = ["2001:1::1", "2001:1::2", "2001:1::3"]

globalIPv6Ranges :: [AddrRange IPv6]
globalIPv6Ranges = ["2001:3::/32", "2001:4:112::/48", "2001:20::/27"]

-- Special-purpose ranges inside global unicast 2000::/3.
specialIPv6 :: [AddrRange IPv6]
specialIPv6 = ["2002::/16", "2001:db8::/32", "3fff::/20"]

-- Parsing and rendering ----------------------------------------------------

parseAddress :: String -> Either String IP
parseAddress str = maybe (Left ("invalid advertised IP address: " ++ str)) Right (parseIP str)

-- IPv6 sorts first, and IPv4-mapped IPv6 addresses stay distinct from IPv4.
familyKey :: IP -> Either IPv6 IPv4
familyKey (IPv6 v6) = Left v6
familyKey (IPv4 v4) = Right v4

byFamily :: [IP] -> [IP]
byFamily = sortOn familyKey . nubOrdOn familyKey

-- Keep the spelling of IPv4-compatible IPv6 addresses that registrations
-- already use. iproute renders their last 32 bits as a dotted quad.
renderAddress :: IP -> String
renderAddress (IPv6 a)
  | (0, 0, 0, low) <- fromIPv6w a,
    low >= 0x10000 =
      "::" ++ showHex (low `shiftR` 16) (':' : showHex (low .&. 0xffff) "")
renderAddress a = show a
