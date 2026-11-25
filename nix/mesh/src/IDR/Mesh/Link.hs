{-# LANGUAGE OverloadedStrings #-}

-- A peer service on the same machine but in another mesh is reached over a
-- veth pair between the two workloads' namespaces. Each end carries its
-- service's address at the local instance, so the other end sees which
-- service it talks to, and routes the other end's address over the pair. Each
-- end's firewall passes only traffic between the two addresses, so neither
-- workload can send from another address or reach anything else through the
-- pair. An end can also reach some of the other end's peers through it: the
-- other end forwards those connections to its WireGuard interface and
-- translates their source to its own mesh address, the only one its peers
-- accept from it.
module IDR.Mesh.Link (createLink, removeLink) where

import Control.Monad (forM_, unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.List (find, intercalate, stripPrefix)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import IDR.Mesh.Common (readJson)
import IDR.Mesh.Identity (MeshPrefix, ServiceId, localInstance, lowerHex, meshAddress)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netns (interfaceAddresses)
import System.Exit (ExitCode (..))

data End = End
  { service :: NS.Workload,
    prefix :: MeshPrefix,
    address :: Text,
    mac :: String,
    -- The peer services of the other end that this end reaches through it.
    reaches :: [ServiceId]
  }

-- The alias marks both interfaces as this link's; the device and firewall
-- table names derive from it.
data Profile = Profile {alias :: String, device :: String, ends :: (End, End)}

instance FromJSON Profile where
  parseJSON = withObject "mesh link" $ \o -> do
    owner <- o .: "alias"
    hash <- maybe (fail "Invalid mesh link alias") pure (stripPrefix "idr-mesh-link-" owner)
    unless (lowerHex 64 (T.pack hash)) $ fail "Invalid mesh link alias"
    listed <- o .: "ends"
    case listed of
      [a, b] -> do
        first <- end "02:00:00:00:00:01" a
        second <- end "02:00:00:00:00:02" b
        unless (service first /= service second && address first /= address second) $
          fail "A mesh link joins two different workloads"
        pure (Profile owner ("idrl" ++ take 11 hash) (first, second))
      _ -> fail "A mesh link has two ends"
    where
      end :: String -> Value -> Parser End
      end hardware = withObject "mesh link end" $ \e -> do
        workload <- e .: "service"
        mesh <- e .: "ipv6Prefix"
        ident <- e .: "id"
        reached <- e .:? "reaches" .!= []
        pure (End workload mesh (meshAddress mesh ident localInstance) hardware reached)

-- The ranges of the services that one end reaches through the other.
routes :: End -> End -> [String]
routes client router = [T.unpack (meshAddress (prefix router) s localInstance) ++ "/96" | s <- reaches client]

pin :: End -> NS.Handle
pin = NS.Pinned . service

table :: Profile -> String
table p = "idr_mesh_link_" ++ drop 4 (device p)

-- An interface as diagnostics name it.
endPath :: Profile -> End -> String
endPath p end = NS.path (pin end) ++ "/" ++ device p

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

linkInfo :: Profile -> End -> IO (Maybe Link)
linkInfo p end = do
  present <- NS.available (pin end)
  if not present
    then pure Nothing
    else find ((== device p) . ifname) <$> (NS.json (pin end) ["ip", "-json", "-details", "link", "show"] :: IO [Link])

paired :: Maybe Link -> Maybe Link -> Bool
paired (Just a) (Just b) = linkIndex a == Just (ifindex b) && linkIndex b == Just (ifindex a)
paired _ _ = False

-- The link's interfaces that exist. An interrupted setup can leave them
-- without the alias, but still paired and with the link's MAC addresses.
interfaces :: Profile -> IO (Maybe Link, Maybe Link)
interfaces p = do
  let (a, b) = ends p
  la <- linkInfo p a
  lb <- linkInfo p b
  let check end other link peer = forM_ link $ \l -> do
        let marked = ifalias l == alias p
            unmarked = null (ifalias l) && paired link peer && (peer >>= hwAddress) == Just (mac other)
        unless (kind l == Just "veth" && hwAddress l == Just (mac end) && (marked || unmarked)) $
          fail ("Refusing to change unowned mesh link interface " ++ endPath p end)
  check a b la lb
  check b a lb la
  pure (la, lb)

-- Never adopt an existing table merely because its name matches.
ownedFirewall :: Profile -> End -> IO Bool
ownedFirewall p end = do
  present <- NS.available (pin end)
  if not present
    then pure False
    else do
      rules <- NS.json (pin end) ["nft", "--json", "list", "ruleset"]
      owned <- either fail pure (parseEither tables rules)
      case owned of
        [] -> pure False
        [Just comment] | comment == alias p -> pure True
        _ -> fail ("Refusing to change unowned mesh link firewall in " ++ NS.path (pin end))
  where
    tables rules = do
      entries <- rules .: "nftables"
      found <- catMaybes <$> traverse (.:? "table") entries
      let owned t = do
            family <- t .: "family" :: Parser String
            name <- t .: "name"
            comment <- t .:? "comment"
            pure [comment | family == "inet", name == table p]
      concat <$> traverse owned found

-- The other end's own address and the services this end reaches through it
-- are all that this end exchanges over the pair. When this end forwards for
-- the other, it passes the other's connections to the services it forwards,
-- and their replies.
firewall :: Profile -> End -> End -> String
firewall p own other =
  unlines $
    [ "add table inet " ++ table p ++ " { comment \"" ++ alias p ++ "\"; }",
      "flush table inet " ++ table p,
      "table inet " ++ table p ++ " {",
      "  chain input {",
      "    type filter hook input priority filter; policy accept;",
      "    iifname " ++ dev ++ " ip6 saddr " ++ set (them : reached) ++ " ip6 daddr " ++ us ++ " accept",
      "    iifname " ++ dev ++ " drop",
      "  }",
      "  chain output {",
      "    type filter hook output priority filter; policy accept;",
      "    oifname " ++ dev ++ " ip6 saddr " ++ us ++ " ip6 daddr " ++ set (them : reached) ++ " accept",
      "    oifname " ++ dev ++ " drop",
      "  }",
      "  chain forward {",
      "    type filter hook forward priority filter; policy accept;"
    ]
      ++ forwarding
        [ "    iifname " ++ dev ++ " oifname " ++ mesh ++ " ip6 saddr " ++ them ++ " ip6 daddr " ++ set forwarded ++ " accept",
          "    iifname " ++ mesh ++ " oifname " ++ dev ++ " ip6 daddr " ++ them ++ " ct state established,related accept"
        ]
      ++ [ "    iifname " ++ dev ++ " drop",
           "    oifname " ++ dev ++ " drop",
           "  }"
         ]
      ++ forwarding
        [ "  chain postrouting {",
          "    type nat hook postrouting priority srcnat; policy accept;",
          "    oifname " ++ mesh ++ " ip6 saddr " ++ them ++ " masquerade",
          "  }"
        ]
      ++ ["}"]
  where
    dev = show (device p)
    mesh = show ("idr-mesh" :: String)
    us = T.unpack (address own)
    them = T.unpack (address other)
    reached = routes own other
    forwarded = routes other own
    forwarding rules = if null forwarded then [] else rules
    set addresses = "{ " ++ intercalate ", " addresses ++ " }"

applyFirewall :: Profile -> End -> End -> IO ()
applyFirewall p own other = do
  _ <- ownedFirewall p own
  (status, _, err) <- NS.tryRun (pin own) ["nft", "--file", "-"] (firewall p own other)
  unless (status == ExitSuccess) $ fail ("Could not apply the mesh link firewall in " ++ NS.path (pin own) ++ ": " ++ err)
  installed <- ownedFirewall p own
  unless installed $ fail ("Mesh link firewall was not installed in " ++ NS.path (pin own))

-- Safe to repeat on a link that is up. The MAC addresses are set when the
-- pair is created: changing one would flush the neighbor entries.
configureEnd :: Profile -> End -> End -> IO ()
configureEnd p own other = do
  let dev = device p
      local = T.unpack (address own)
      ip = NS.run (pin own) . ("ip" :)
  ip ["link", "set", "dev", dev, "alias", alias p]
  ip ["link", "set", "dev", dev, "addrgenmode", "none"]
  NS.run (pin own) $
    ["sysctl", "--quiet", "--write"]
      ++ ["net.ipv6.conf." ++ dev ++ "." ++ field ++ "=0" | field <- ["forwarding", "accept_ra", "autoconf"]]
  applyFirewall p own other
  ip ["-6", "address", "replace", local ++ "/128", "dev", dev, "nodad"]
  -- Compare kernel-rendered addresses so IPv6 compression cannot hide a match.
  assigned <- interfaceAddresses (pin own) dev (Just (local ++ "/128"))
  current <- interfaceAddresses (pin own) dev Nothing
  case assigned of
    (kept, _) : _ -> forM_ current $ \(old, bits) ->
      when (old /= kept) $ ip ["-6", "address", "delete", old ++ "/" ++ show bits, "dev", dev]
    [] -> fail ("Mesh link address missing from " ++ endPath p own)
  ip ["-6", "neighbor", "replace", T.unpack (address other), "lladdr", mac other, "nud", "permanent", "dev", dev]
  -- Forwarding only on these two interfaces leaves the workload a host. It
  -- stays on for the mesh interface once the link goes: what peers send on
  -- from there is dropped by the firewall of each other interface, or by the
  -- WireGuard peers it would reach, which only accept this workload's address.
  unless (null (reaches other)) . NS.run (pin own) $
    ["sysctl", "--quiet", "--write"]
      ++ ["net.ipv6.conf." ++ interface ++ ".force_forwarding=1" | interface <- [dev, "idr-mesh"]]

-- Creates the pair or updates it in place, so connections over it survive.
createLink :: FilePath -> IO ()
createLink file = do
  p <- readJson file
  let (a, b) = ends p
  forM_ [a, b] $ \end -> do
    present <- NS.available (pin end)
    unless present $ fail ("Missing mesh workload namespace " ++ NS.path (pin end))
  (la, lb) <- interfaces p
  unless (paired la lb) $ do
    deleteInterfaces p (la, lb)
    NS.run (pin a) $
      ["ip", "link", "add", "name", device p, "address", mac a, "type", "veth"]
        ++ ["peer", "name", device p, "netns", NS.path (pin b), "address", mac b]
  configureEnd p a b
  configureEnd p b a
  forM_ [(a, b), (b, a)] $ \(own, other) -> do
    let route = NS.run (pin own) . (["ip", "-6", "route", "replace"] ++) . (++ ["dev", device p, "proto", "static"])
    NS.run (pin own) ["ip", "link", "set", "dev", device p, "up"]
    route [T.unpack (address other) ++ "/128"]
    forM_ (routes own other) $ \range -> route [range, "via", T.unpack (address other)]

-- Deleting one end of a pair destroys the other.
deleteInterfaces :: Profile -> (Maybe Link, Maybe Link) -> IO ()
deleteInterfaces p (la, lb) = do
  let (a, b) = ends p
      delete end = NS.run (pin end) ["ip", "link", "delete", "dev", device p]
  when (isJust la) (delete a)
  remaining <- if isJust la then linkInfo p b else pure lb
  when (isJust remaining) (delete b)

-- Either namespace may already be gone.
removeLink :: FilePath -> IO ()
removeLink file = do
  p <- readJson file
  let (a, b) = ends p
  found <- interfaces p
  owned <- traverse (ownedFirewall p) [a, b]
  deleteInterfaces p found
  forM_ (zip [a, b] owned) $ \(end, installed) ->
    when installed $ NS.run (pin end) ["nft", "delete", "table", "inet", table p]
