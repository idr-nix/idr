{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Dns.Transport (createDns, configureDns, removeDns, createLink, removeLink) where

import Control.Monad (forM_, unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.List (find, isPrefixOf)
import Data.Maybe (catMaybes, isJust)
import Data.Text qualified as T
import GHC.Generics (Generic)
import IDR.Mesh.Common
import IDR.Mesh.Dns (validDnsAddress)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netns (interfaceAddresses)
import IDR.Mesh.PeerData (lowerHex)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

clientDevice, firewallTable, serverOwner :: String
clientDevice = "idr-dns"
firewallTable = "idr_mesh_dns"
serverOwner = "idr-mesh-dns-server"

-- Keep the inventory and persisted link-state fields compatible across restarts.
data Profile = Profile
  { service :: NS.Workload,
    interface :: String,
    alias :: String,
    clientAddress :: String,
    serverAddress :: String,
    clientMac :: String,
    serverMac :: String,
    clientFirewall :: FilePath
  }
  deriving (Generic)

instance ToJSON Profile

instance FromJSON Profile where
  parseJSON value = do
    p <- genericParseJSON defaultOptions value
    unless (validDevice (interface p) && not (null (alias p))) $
      fail "Invalid mesh DNS link identity"
    let client = T.pack (clientAddress p)
        server = T.pack (serverAddress p)
        subnet = fst . T.breakOnEnd ":"
        distinct = all validDnsAddress [client, server] && client /= server
    unless (distinct && subnet client == subnet server) $
      fail "Mesh DNS addresses must be distinct full lowercase ULAs in the same /112"
    unless (clientMac p == "02:00:00:00:00:01" && serverMac p == "02:00:00:00:00:02") $
      fail "Invalid mesh DNS link MAC addresses"
    unless ("/nix/store/" `isPrefixOf` clientFirewall p) $
      fail "Expected DNS firewall rules from the Nix store"
    pure p
    where
      validDevice ('d' : suffix) = lowerHex 14 (T.pack suffix)
      validDevice _ = False

profileFromInventory :: String -> FilePath -> IO Profile
profileFromInventory name file =
  readJson file >>= either fail pure . parseEither (withObject "DNS inventory" profile)
  where
    profile inventory = do
      services <- inventory .: "services"
      fields <- services .: Key.fromString name
      parseJSON (Object (KM.insert "service" (String (T.pack name)) fields))

-- See `encodeState`.
profileVersion :: Int
profileVersion = 1

readProfile :: FilePath -> IO (Maybe Profile)
readProfile = readState profileVersion

data End = End {namespace :: NS.Handle, device, address, mac :: String}

-- An interface as diagnostics name it.
endPath :: End -> String
endPath end = NS.path (namespace end) ++ "/" ++ device end

clientEnd, serverEnd :: Profile -> End
clientEnd p = End (NS.Pinned (service p)) clientDevice (clientAddress p) (clientMac p)
serverEnd p = End NS.SharedDns (interface p) (serverAddress p) (serverMac p)

-- Never adopt an existing table merely because its name matches.
ownedFirewall :: NS.Handle -> String -> IO Bool
ownedFirewall pin owner = do
  present <- NS.available pin
  if not present
    then pure False
    else do
      rules <- NS.json pin ["nft", "--json", "list", "ruleset"]
      owned <- either fail pure $ parseEither tables rules
      case owned of
        [] -> pure False
        [Just comment] | comment == owner -> pure True
        _ -> fail ("Refusing to change unowned mesh DNS firewall in " ++ NS.path pin)
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

applyFirewall :: NS.Handle -> FilePath -> String -> IO ()
applyFirewall pin file owner = do
  rules <- canonicalizePath file
  unless ("/nix/store/" `isPrefixOf` rules) $ fail "Expected DNS firewall rules from the Nix store"
  _ <- ownedFirewall pin owner
  NS.run pin ["nft", "--file", rules]
  installed <- ownedFirewall pin owner
  unless installed $ fail ("DNS firewall was not installed in " ++ NS.path pin)

sysctl :: NS.Handle -> [String] -> IO ()
sysctl pin entries = NS.run pin (["sysctl", "--quiet", "--write"] ++ map (++ "=0") entries)

configureDns :: FilePath -> IO ()
configureDns rules = do
  sysctl NS.SharedDns $
    ["net.ipv4.ip_forward"]
      ++ [ "net." ++ key ++ "." ++ scope ++ "." ++ field
         | (key, fields) <- routing,
           scope <- ["all", "default"],
           field <- fields
         ]
  applyFirewall NS.SharedDns rules serverOwner
  NS.run NS.SharedDns ["ip", "link", "set", "dev", "lo", "up"]
  where
    routing =
      [("ipv4.conf", ["forwarding"]), ("ipv6.conf", ["forwarding", "accept_ra", "autoconf"])]

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
  present <- NS.available (namespace end)
  if not present
    then pure Nothing
    else do
      links <- NS.json (namespace end) ["ip", "-json", "-details", "link", "show"] :: IO [Link]
      pure $ find ((== device end) . ifname) links

paired :: Maybe Link -> Maybe Link -> Bool
paired (Just a) (Just b) = linkIndex a == Just (ifindex b) && linkIndex b == Just (ifindex a)
paired _ _ = False

profileLinks :: Profile -> IO (Maybe Link, Maybe Link)
profileLinks p = do
  client <- linkInfo (clientEnd p)
  server <- linkInfo (serverEnd p)
  let check end peerEnd link peer = forM_ link $ \l -> do
        -- An interrupted setup can leave only the peer's ownership alias installed.
        let partial =
              paired link peer
                && null (ifalias l)
                && (ifalias <$> peer) == Just (alias p)
                && hwAddress l == Just (mac end)
                && (peer >>= hwAddress) == Just (mac peerEnd)
        unless (kind l == Just "veth" && (ifalias l == alias p || partial)) $
          fail ("Refusing to change unowned mesh DNS interface " ++ endPath end)
  check (clientEnd p) (serverEnd p) client server
  check (serverEnd p) (clientEnd p) server client
  pure (client, server)

linkSet :: End -> [String] -> IO ()
linkSet end args = NS.run (namespace end) (["ip", "link", "set", "dev", device end] ++ args)

deleteLinks :: Profile -> Maybe Link -> IO ()
deleteLinks p client = do
  let delete end = NS.run (namespace end) ["ip", "link", "delete", "dev", device end]
  when (isJust client) $ delete (clientEnd p)
  -- Deleting one end of a veth pair normally destroys the other end.
  server <- linkInfo (serverEnd p)
  forM_ server $ \l -> do
    unless (kind l == Just "veth" && ifalias l == alias p) $
      fail ("Refusing to delete unowned mesh DNS interface " ++ interface p)
    delete (serverEnd p)

removeProfile :: Profile -> IO ()
removeProfile p = do
  (client, _) <- profileLinks p
  let name = namespace (clientEnd p)
  installed <- ownedFirewall name (alias p)
  deleteLinks p client
  when installed $ NS.run name ["nft", "delete", "table", "inet", firewallTable]

configureEnd :: End -> End -> IO ()
configureEnd end peer = do
  let name = namespace end
      dev = device end
  linkSet end ["nomaster", "mtu", "1280", "address", mac end, "addrgenmode", "none"]
  sysctl
    name
    [ "net." ++ key ++ ".conf." ++ dev ++ "." ++ field
    | (key, field) <- routing
    ]
  NS.run name ["ip", "-6", "address", "replace", address end ++ "/112", "dev", dev, "nodad"]
  -- Compare kernel-rendered addresses so IPv6 compression cannot hide a match.
  assigned <- interfaceAddresses name dev (Just (address end ++ "/128"))
  current <- interfaceAddresses name dev Nothing
  case assigned of
    (assignedAddress, _) : _ -> forM_ current $ \(old, bits) ->
      when (old /= assignedAddress) $
        NS.run name ["ip", "-6", "address", "delete", old ++ "/" ++ show bits, "dev", dev]
    [] -> fail ("Mesh DNS address missing from " ++ endPath end)
  NS.run name $
    ["ip", "-6", "neighbor", "replace", address peer]
      ++ ["lladdr", mac peer, "nud", "permanent", "dev", dev]
  where
    routing =
      [("ipv4", "forwarding"), ("ipv6", "forwarding"), ("ipv6", "accept_ra"), ("ipv6", "autoconf")]

createLink :: String -> FilePath -> FilePath -> IO ()
createLink name inventory stateFile = do
  p <- profileFromInventory name inventory
  let client = clientEnd p
      server = serverEnd p
      identity old = (service old, interface old, alias old)
  forM_ [client, server] $ \end -> do
    present <- NS.available (namespace end)
    unless present $ fail ("Missing mesh DNS link namespace " ++ NS.path (namespace end))
  installed <- ownedFirewall NS.SharedDns serverOwner
  unless installed $ fail "Mesh DNS namespace firewall is not installed"
  previous <- readProfile stateFile
  forM_ previous $ \old -> when (identity old /= identity p) (removeProfile old)
  (c, s) <- profileLinks p
  _ <- ownedFirewall (namespace client) (alias p)
  createDirectoryIfMissing True (takeDirectory stateFile)
  atomicWrite stateFile (encodeState profileVersion p)
  applyFirewall (namespace client) (clientFirewall p) (alias p)
  if paired c s
    then mapM_ (\end -> linkSet end ["down"]) [server, client]
    else do
      deleteLinks p c
      NS.run NS.SharedDns $
        ["ip", "link", "add", "name", device server, "mtu", "1280", "address", mac server]
          ++ ["type", "veth", "peer", "name", device client, "netns", NS.path (namespace client)]
          ++ ["mtu", "1280", "address", mac client]
  mapM_ (\end -> linkSet end ["alias", alias p]) [server, client]
  configureEnd server client
  configureEnd client server
  mapM_ (\end -> linkSet end ["up"]) [server, client]

createDns :: FilePath -> IO ()
createDns rules = NS.create NS.SharedDns >> configureDns rules

removeDns :: IO ()
removeDns = NS.remove NS.SharedDns

-- A state file this release cannot read, for example one an older release
-- wrote, falls back to the inventory the link was created from.
removeLink :: String -> FilePath -> FilePath -> IO ()
removeLink name inventory stateFile = do
  present <- doesFileExist stateFile
  when present $ do
    previous <- readProfile stateFile
    p <- maybe (profileFromInventory name inventory) pure previous
    removeProfile p
    removeIfExists stateFile
