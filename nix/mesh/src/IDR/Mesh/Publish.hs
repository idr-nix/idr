{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- A workload's published ports reach it over a veth pair from the host
-- namespace, where nftables forwards them with DNAT and keeps the client's
-- address. The workload's default route leads through the pair, so replies
-- need no source address of their own, as UDP servers on a wildcard address
-- send them. Connections that the workload's internet access allows leave
-- through the pair too, and the host translates their source address. The
-- workload's firewall admits only new connections to its published ports and
-- opens only those allowed out, so the link carries nothing else; the host
-- drops what would pass anyway.
module IDR.Mesh.Publish (createLink, removeLink) where

import Control.Monad (forM_, unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.IP (IP (IPv4, IPv6))
import Data.List (find, isPrefixOf, stripPrefix)
import Data.Maybe (catMaybes, isJust)
import Data.Text qualified as T
import GHC.Generics (Generic)
import IDR.Mesh.Common
import IDR.Mesh.IP (parseIP)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.PeerData (lowerHex)
import IDR.Mesh.Process (callChild)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

workloadDevice, firewallTable :: String
workloadDevice = "idr-publish"
firewallTable = "idr_mesh_publish"

data Profile = Profile
  { service :: NS.Workload,
    interface :: String,
    alias :: String,
    hostAddress6 :: String,
    workloadAddress6 :: String,
    hostAddress4 :: String,
    workloadAddress4 :: String,
    hostMac :: String,
    workloadMac :: String,
    firewall :: FilePath
  }
  deriving (Generic)

instance ToJSON Profile

instance FromJSON Profile where
  parseJSON value = do
    p <- genericParseJSON defaultOptions value
    unless (validDevice (interface p) && validAlias (alias p)) $
      fail "Invalid mesh publish link identity"
    unless (pair isIPv6 (hostAddress6 p) (workloadAddress6 p) && pair isIPv4 (hostAddress4 p) (workloadAddress4 p)) $
      fail "Invalid mesh publish link addresses"
    unless (hostMac p == "02:00:00:00:00:01" && workloadMac p == "02:00:00:00:00:02") $
      fail "Invalid mesh publish link MAC addresses"
    unless ("/nix/store/" `isPrefixOf` firewall p) $
      fail "Expected publish firewall rules from the Nix store"
    pure p
    where
      validDevice name = maybe False (lowerHex 11 . T.pack) (stripPrefix "idrp" name)
      validAlias name = maybe False (lowerHex 64 . T.pack) (stripPrefix "idr-mesh-publish-" name)
      pair family a b = all (maybe False family . parseIP) [a, b] && parseIP a /= parseIP b
      isIPv6 (IPv6 _) = True
      isIPv6 _ = False
      isIPv4 (IPv4 _) = True
      isIPv4 _ = False

-- Nothing when the workload neither publishes ports nor has internet access,
-- which leaves it without an inventory.
profileFromInventory :: String -> FilePath -> IO (Maybe Profile)
profileFromInventory name file = do
  present <- doesFileExist file
  if present
    then readJson file >>= either fail pure . parseEither (withObject "publish inventory" profile)
    else pure Nothing
  where
    profile inventory = do
      services <- inventory .: "services"
      fields <- services .:? Key.fromString name
      traverse (parseJSON . Object . KM.insert "service" (String (T.pack name))) fields

-- See `encodeState`.
profileVersion :: Int
profileVersion = 1

readProfile :: FilePath -> IO (Maybe Profile)
readProfile = readState profileVersion

-- The host end lives in the namespace that runs this command.
data Side = Host | Workload NS.Workload

sideName :: Side -> String
sideName Host = "the host namespace"
sideName (Workload ns) = NS.path (NS.Pinned ns)

available :: Side -> IO Bool
available Host = pure True
available (Workload ns) = NS.available (NS.Pinned ns)

run :: Side -> [String] -> IO ()
run Host (command : args) = callChild command args
run Host [] = fail "Missing command"
run (Workload ns) command = NS.run (NS.Pinned ns) command

json :: (FromJSON a) => Side -> [String] -> IO a
json Host (command : args) = readProcessJson command args
json Host [] = fail "Missing command"
json (Workload ns) command = NS.json (NS.Pinned ns) command

data End = End {side :: Side, device, mac, address6, address4 :: String, forwards :: Bool}

-- An interface as diagnostics name it.
endPath :: End -> String
endPath end = sideName (side end) ++ "/" ++ device end

-- The host end forwards the published connections and their replies.
hostEnd, workloadEnd :: Profile -> End
hostEnd p = End Host (interface p) (hostMac p) (hostAddress6 p) (hostAddress4 p) True
workloadEnd p = End (Workload (service p)) workloadDevice (workloadMac p) (workloadAddress6 p) (workloadAddress4 p) False

workloadSide :: Profile -> Side
workloadSide = Workload . service

-- Never adopt an existing table merely because its name matches.
ownedFirewall :: Profile -> IO Bool
ownedFirewall p = do
  let pin = workloadSide p
  present <- available pin
  if not present
    then pure False
    else do
      rules <- json pin ["nft", "--json", "list", "ruleset"]
      owned <- either fail pure $ parseEither tables rules
      case owned of
        [] -> pure False
        [Just comment] | comment == alias p -> pure True
        _ -> fail ("Refusing to change unowned mesh publish firewall in " ++ sideName pin)
  where
    tables rules = do
      entries <- rules .: "nftables"
      found <- catMaybes <$> traverse (.:? "table") entries
      let owned table = do
            family <- table .: "family" :: Parser String
            tableName <- table .: "name"
            comment <- table .:? "comment"
            pure [comment | family == "inet", tableName == firewallTable]
      concat <$> traverse owned found

applyFirewall :: Profile -> IO ()
applyFirewall p = do
  rules <- canonicalizePath (firewall p)
  unless ("/nix/store/" `isPrefixOf` rules) $ fail "Expected publish firewall rules from the Nix store"
  _ <- ownedFirewall p
  run (workloadSide p) ["nft", "--file", rules]
  installed <- ownedFirewall p
  unless installed $ fail ("Publish firewall was not installed in " ++ sideName (workloadSide p))

data Link = Link
  { ifname :: String,
    ifindex :: Int,
    linkIndex :: Maybe Int,
    ifalias :: String,
    kind :: Maybe String,
    hwAddress :: Maybe String
  }

instance FromJSON Link where
  parseJSON = withObject "ip link" $ \o -> do
    info <- o .:? "linkinfo"
    Link
      <$> o .: "ifname"
      <*> o .: "ifindex"
      <*> o .:? "link_index"
      <*> o .:? "ifalias" .!= ""
      <*> maybe (pure Nothing) (.:? "info_kind") info
      <*> o .:? "address"

linkInfo :: End -> IO (Maybe Link)
linkInfo end = do
  present <- available (side end)
  if not present
    then pure Nothing
    else do
      links <- json (side end) ["ip", "-json", "-details", "link", "show"] :: IO [Link]
      pure $ find ((== device end) . ifname) links

paired :: Maybe Link -> Maybe Link -> Bool
paired (Just a) (Just b) = linkIndex a == Just (ifindex b) && linkIndex b == Just (ifindex a)
paired _ _ = False

profileLinks :: Profile -> IO (Maybe Link, Maybe Link)
profileLinks p = do
  workload <- linkInfo (workloadEnd p)
  host <- linkInfo (hostEnd p)
  let check end peerEnd link peer = forM_ link $ \l -> do
        -- An interrupted setup can leave only the peer's ownership alias installed.
        let partial =
              paired link peer
                && null (ifalias l)
                && (ifalias <$> peer) == Just (alias p)
                && hwAddress l == Just (mac end)
                && (peer >>= hwAddress) == Just (mac peerEnd)
        unless (kind l == Just "veth" && (ifalias l == alias p || partial)) $
          fail ("Refusing to change unowned mesh publish interface " ++ endPath end)
  check (workloadEnd p) (hostEnd p) workload host
  check (hostEnd p) (workloadEnd p) host workload
  pure (workload, host)

linkSet :: End -> [String] -> IO ()
linkSet end args = run (side end) (["ip", "link", "set", "dev", device end] ++ args)

deleteLinks :: Profile -> Maybe Link -> IO ()
deleteLinks p workload = do
  let delete end = run (side end) ["ip", "link", "delete", "dev", device end]
  when (isJust workload) $ delete (workloadEnd p)
  -- Deleting one end of a veth pair normally destroys the other end.
  host <- linkInfo (hostEnd p)
  forM_ host $ \l -> do
    unless (kind l == Just "veth" && ifalias l == alias p) $
      fail ("Refusing to delete unowned mesh publish interface " ++ interface p)
    delete (hostEnd p)

-- The default routes go away with the link. Mesh peers and DNS keep their
-- more specific routes.
configureRouting :: Profile -> IO ()
configureRouting p =
  forM_ [("-6", hostAddress6 p), ("-4", hostAddress4 p)] $ \(family, gateway) ->
    run (workloadSide p) ["ip", family, "route", "replace", "default", "via", gateway, "dev", workloadDevice]

removeProfile :: Profile -> IO ()
removeProfile p = do
  (workload, _) <- profileLinks p
  installed <- ownedFirewall p
  deleteLinks p workload
  when installed $ run (workloadSide p) ["nft", "delete", "table", "inet", firewallTable]

sysctl :: Side -> [String] -> IO ()
sysctl pin entries = run pin (["sysctl", "--quiet", "--write"] ++ map (++ "=0") entries)

-- A device's addresses of one family, optionally only those in a subnet.
addresses :: Side -> String -> String -> Maybe String -> IO [(String, Int)]
addresses pin family dev subnet = do
  rows <- json pin (["ip", "-json", family, "address", "show", "dev", dev] ++ maybe [] (\s -> ["to", s]) subnet) :: IO [Object]
  info <- either fail pure $ concat <$> traverse (parseEither (.: "addr_info")) rows
  either fail pure $ concat <$> traverse (parseEither address) info
  where
    -- iproute2 emits an empty object for addresses outside the requested subnet.
    address row = do
      local <- row .:? "local"
      case local of
        Nothing -> pure []
        Just name -> do
          bits <- row .: "prefixlen"
          pure [(name, bits)]

assign :: End -> String -> String -> Int -> Int -> IO ()
assign end family address prefix host = do
  let pin = side end
      dev = device end
      nodad = ["nodad" | family == "-6"]
  run pin (["ip", family, "address", "replace", address ++ "/" ++ show prefix, "dev", dev] ++ nodad)
  -- Compare kernel-rendered addresses so IPv6 compression cannot hide a match.
  assigned <- addresses pin family dev (Just (address ++ "/" ++ show host))
  current <- addresses pin family dev Nothing
  case assigned of
    (assignedAddress, _) : _ -> forM_ current $ \(old, bits) ->
      when (old /= assignedAddress) $
        run pin ["ip", family, "address", "delete", old ++ "/" ++ show bits, "dev", dev]
    [] -> fail ("Mesh publish address missing from " ++ endPath end)

-- Safe to repeat on a link that is up. Its MAC addresses are set when it is
-- created: changing one would flush the neighbor entries.
configureEnd :: End -> End -> IO ()
configureEnd end peer = do
  let pin = side end
      dev = device end
  linkSet end ["addrgenmode", "none"]
  sysctl pin $
    ["net.ipv6.conf." ++ dev ++ "." ++ field | field <- ["accept_ra", "autoconf"]]
      ++ ["net." ++ key ++ ".conf." ++ dev ++ ".forwarding" | not (forwards end), key <- ["ipv4", "ipv6"]]
  assign end "-6" (address6 end) 112 128
  assign end "-4" (address4 end) 31 32
  forM_ [("-6", address6 peer), ("-4", address4 peer)] $ \(family, address) ->
    run pin ["ip", family, "neighbor", "replace", address, "lladdr", mac peer, "nud", "permanent", "dev", dev]

-- Creates the link, updates it in place, or removes it when the workload no
-- longer needs it. A reload runs this again: an existing link stays up,
-- so the workload keeps its connections.
createLink :: String -> FilePath -> FilePath -> IO ()
createLink name inventory stateFile = do
  wanted <- profileFromInventory name inventory
  previous <- readProfile stateFile
  case wanted of
    Nothing -> do
      mapM_ removeProfile previous
      removeIfExists stateFile
    Just p -> do
      let host = hostEnd p
          workload = workloadEnd p
          identity old = (service old, interface old, alias old)
      present <- available (workloadSide p)
      unless present $ fail ("Missing mesh workload namespace " ++ sideName (workloadSide p))
      forM_ previous $ \old -> when (identity old /= identity p) (removeProfile old)
      (w, h) <- profileLinks p
      _ <- ownedFirewall p
      createDirectoryIfMissing True (takeDirectory stateFile)
      atomicWrite stateFile (encodeState profileVersion p)
      applyFirewall p
      unless (paired w h) $ do
        deleteLinks p w
        run Host $
          ["ip", "link", "add", "name", device host, "address", mac host, "type", "veth"]
            ++ ["peer", "name", device workload, "netns", NS.path (NS.Pinned (service p)), "address", mac workload]
      mapM_ (\end -> linkSet end ["alias", alias p]) [host, workload]
      configureEnd host workload
      configureEnd workload host
      mapM_ (`linkSet` ["up"]) [host, workload]
      configureRouting p

-- A state file this release cannot read falls back to the inventory the link
-- was created from.
removeLink :: String -> FilePath -> FilePath -> IO ()
removeLink name inventory stateFile = do
  present <- doesFileExist stateFile
  when present $ do
    previous <- readProfile stateFile
    p <- maybe (profileFromInventory name inventory) (pure . Just) previous
    mapM_ removeProfile p
    removeIfExists stateFile
