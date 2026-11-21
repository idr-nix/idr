{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.WireGuard
  ( Subnet (..),
    Interface (..),
    Peer (..),
    serviceRoute,
    readInterface,
    removePeers,
    addConfiguration,
    setPrivateKey,
  )
where

import Control.Monad (guard, mfilter, unless)
import Data.Char (isDigit)
import Data.IP (IP (IPv6), fromIPv6)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import IDR.Mesh.IP (parseIP)
import IDR.Mesh.Identity
  ( InstanceId,
    MeshPrefix,
    ServiceId,
    instanceIdFromWord32,
    meshPrefixText,
    parseInstanceId,
    parseServiceId,
  )
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.PSK.Secret (Secret, parseSecret)
import IDR.Mesh.PublicKey (PublicKey, parsePublicKey, publicKeyText)
import Numeric (showHex)
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

data Subnet = Subnet
  { subnetServiceId :: ServiceId,
    subnetInstanceId :: InstanceId,
    subnetAddress :: Text
  }
  deriving (Eq, Show)

meshSubnet :: MeshPrefix -> Text -> Maybe Subnet
meshSubnet prefix address = do
  IPv6 host <- parseIP (T.unpack address)
  let groups = map (T.justifyRight 4 '0' . T.pack . flip showHex "") (fromIPv6 host)
      suffix = drop 6 groups
  guard (T.intercalate ":" (take 3 groups) == meshPrefixText prefix)
  service <- either (const Nothing) Just $ parseServiceId (T.concat $ take 3 $ drop 3 groups)
  ident <- either (const Nothing) Just $ parseInstanceId (T.concat suffix)
  pure $ Subnet service ident (T.intercalate ":" groups)

serviceRoute :: MeshPrefix -> Text -> Maybe ServiceId
serviceRoute prefix cidr = do
  subnet <- T.stripSuffix "/96" cidr >>= meshSubnet prefix
  guard (subnetInstanceId subnet == instanceIdFromWord32 0)
  pure (subnetServiceId subnet)

-- wg may print a malformed private key or PSK to stderr. Keep
-- subprocess output private on every failure.
wireguard :: NS.Workload -> [String] -> String -> IO Text
wireguard ns args stdinText = do
  (status, out, _) <- NS.tryRun (NS.Pinned ns) ("wg" : args) stdinText
  case status of
    ExitSuccess -> pure (T.strip (T.pack out))
    ExitFailure n -> fail ("Could not access mesh WireGuard interface (exit " ++ show n ++ ")")

-- The mesh interface: its own public key and the installed peers.
data Interface = Interface {ownKey :: PublicKey, listenPort :: Int, peers :: Map PublicKey Peer}

data Peer = Peer
  { -- Set when the peer's only allowed IP is a mesh instance address.
    subnet :: Maybe Subnet,
    -- Absent when wg reports none.
    presharedKey :: Maybe Secret,
    -- Seconds since the epoch of the last handshake, if there was one.
    handshake :: Maybe Integer
  }

-- One `wg show dump`. Its first line also holds the private key, which is
-- not kept.
readInterface :: NS.Workload -> MeshPrefix -> IO Interface
readInterface ns prefix = do
  output <- wireguard ns ["show", "idr-mesh", "dump"] ""
  either fail pure (parseDump prefix (map (T.splitOn "\t") (T.lines output)))

parseDump :: MeshPrefix -> [[Text]] -> Either String Interface
parseDump prefix = \case
  [_, key, port, _] : rows -> do
    own <- parsePublicKey key
    listening <- maybe (Left "Invalid WireGuard listen port") Right (readMaybe (T.unpack port))
    entries <- traverse peer rows
    let table = Map.fromList entries
    unless (Map.size table == length entries) $ Left "Duplicate peer in WireGuard output"
    pure (Interface own listening table)
  _ -> Left "Invalid WireGuard interface output"
  where
    peer [key, psk, _, allowed, latest, _, _, _] = do
      publicKey <- parsePublicKey key
      secret <- if psk == "(none)" then pure Nothing else Just <$> parseSecret psk
      at <- seconds latest
      let instance' = T.stripSuffix "/128" allowed >>= meshSubnet prefix
      pure (publicKey, Peer instance' secret (mfilter (> 0) (Just at)))
    peer _ = Left "Invalid WireGuard peer output"
    seconds value
      | not (T.null value) && T.all isDigit value = Right (read (T.unpack value) :: Integer)
      | otherwise = Left "Invalid WireGuard handshake time"

removePeers :: NS.Workload -> [PublicKey] -> IO ()
removePeers _ [] = pure ()
removePeers ns keys = do
  let removal k = ["peer", T.unpack (publicKeyText k), "remove"]
  _ <- wireguard ns (["set", "idr-mesh"] ++ concatMap removal keys) ""
  pure ()

addConfiguration :: NS.Workload -> Text -> IO ()
addConfiguration namespace config = do
  _ <- wireguard namespace ["addconf", "idr-mesh", "/dev/stdin"] (T.unpack config)
  pure ()

setPrivateKey :: NS.Workload -> FilePath -> IO ()
setPrivateKey ns path = do
  _ <- wireguard ns ["set", "idr-mesh", "private-key", path] ""
  pure ()
