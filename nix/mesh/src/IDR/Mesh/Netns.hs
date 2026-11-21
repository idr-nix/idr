{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Netns
  ( create,
    remove,
    allocatePort,
    listenPort,
    configureAddress,
    interfaceAddresses,
  )
where

import Control.Monad (forM_, unless, when)
import Data.Aeson ((.:), (.:?))
import Data.Aeson.Types (Object, parseEither)
import Data.ByteString.Char8 qualified as BS
import Data.IntSet qualified as IntSet
import Data.List (isInfixOf)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import IDR.Mesh.Common (readOptionalFile)
import IDR.Mesh.Identity (InstanceId, MeshPrefix, ServiceId, meshAddress, meshPrefixText)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Process (callChild)
import IDR.Mesh.WireGuard (setPrivateKey)
import Numeric (readHex)
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

create :: NS.Workload -> FilePath -> IO ()
create ns privateKey = do
  NS.create handle
  links <- NS.json handle ["ip", "-json", "link", "show"] :: IO [Object]
  names <- either fail pure $ traverse (parseEither (.: "ifname")) links
  -- Create from the host namespace so WireGuard's UDP socket stays there.
  unless (("idr-mesh" :: Text) `elem` names) $
    ip ["link", "add", "dev", "idr-mesh", "netns", NS.path handle, "type", "wireguard"]
  setPrivateKey ns privateKey
  where
    handle = NS.Pinned ns

remove :: NS.Workload -> IO ()
remove ns = do
  -- Close the host UDP socket even if a straggler keeps the namespace alive.
  pinned <- NS.available handle
  when pinned $ do
    devices <- NS.output handle ["wg", "show", "interfaces"]
    when ("idr-mesh" `elem` words devices) $
      NS.run handle ["ip", "link", "delete", "dev", "idr-mesh"]
  NS.remove handle
  where
    handle = NS.Pinned ns

ip :: [String] -> IO ()
ip = callChild "ip"

listenPort :: NS.Workload -> IO Int
listenPort ns = do
  output <- NS.output (NS.Pinned ns) ["wg", "show", "idr-mesh", "listen-port"]
  maybe (fail "Invalid WireGuard listen port") pure (readMaybe output)

tryPort :: NS.Workload -> Int -> IO Bool
tryPort ns port = do
  set <- tryCommand ["wg", "set", "idr-mesh", "listen-port", show port]
  if set then tryCommand ["ip", "link", "set", "dev", "idr-mesh", "up"] else pure False
  where
    tryCommand args = do
      (status, _, err) <- NS.tryRun (NS.Pinned ns) args ""
      case status of
        ExitSuccess -> pure True
        _
          | ": Address already in use" `isInfixOf` err -> pure False
          | otherwise -> fail (unwords args ++ " failed: " ++ err)

occupiedPorts :: IO IntSet.IntSet
occupiedPorts = do
  tables <- traverse readOptionalFile ["/proc/net/udp", "/proc/net/udp6"]
  let rows = concatMap (drop 1 . BS.lines) (catMaybes tables)
  pure (IntSet.fromList (mapMaybe parseLine rows))
  where
    parseLine row = case BS.words row of
      _ : endpoint : _ ->
        case readHex (BS.unpack (BS.drop 1 (BS.dropWhile (/= ':') endpoint))) of
          [(port, "")] -> Just port
          _ -> Nothing
      _ -> Nothing

allocatePort :: NS.Workload -> Int -> Int -> IO ()
allocatePort namespace first lastPort = do
  unless (1 <= first && first <= lastPort && lastPort <= 65535) $
    fail "Expected a UDP port range with 1 <= FIRST <= LAST <= 65535"
  current <- listenPort namespace
  let inRange = current >= first && current <= lastPort
  retained <- if inRange then tryPort namespace current else pure False
  unless retained $ do
    occupied <- occupiedPorts
    pick (filter (`IntSet.notMember` occupied) [first .. lastPort])
  where
    pick [] = fail ("No available mesh UDP port in " ++ show first ++ "-" ++ show lastPort)
    pick (port : rest) = do
      bound <- tryPort namespace port
      unless bound (pick rest)

configureAddress :: NS.Workload -> ServiceId -> MeshPrefix -> InstanceId -> IO ()
configureAddress ns service prefix instanceId = do
  let cidr = T.unpack (meshAddress prefix service instanceId) ++ "/128"
      change op address =
        NS.run (NS.Pinned ns) ["ip", "-6", "address", op, address, "dev", "idr-mesh"]
      addresses = interfaceAddresses (NS.Pinned ns) "idr-mesh" . Just
  change "replace" cidr
  -- Match the kernel's spelling when pruning old /128 addresses.
  current <- addresses cidr
  assigned <- case current of
    (local, _) : _ -> pure local
    [] -> fail "Mesh address missing after ip address replace"
  existing <- addresses (T.unpack (meshPrefixText prefix) ++ "::/48")
  forM_ existing $ \(local, bits) ->
    when (bits == 128 && local /= assigned) $ change "del" (local ++ "/128")

interfaceAddresses :: NS.Handle -> String -> Maybe String -> IO [(String, Int)]
interfaceAddresses pin device subnet = do
  let args =
        ["ip", "-json", "-6", "address", "show", "dev", device]
          ++ maybe [] (\s -> ["to", s]) subnet
  rows <- NS.json pin args :: IO [Object]
  info <- either fail pure $ concat <$> traverse (parseEither (.: "addr_info")) rows
  either fail pure $ fmap concat $ traverse (parseEither address) info
  where
    address row = do
      -- iproute2 emits an empty object for addresses outside the requested subnet.
      local <- row .:? "local"
      case local of
        Nothing -> pure []
        Just name -> do
          bits <- row .: "prefixlen"
          pure [(name, bits)]
