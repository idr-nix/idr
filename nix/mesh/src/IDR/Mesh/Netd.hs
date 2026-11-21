{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- The protocol between the agent and netd, and the workload status netd
-- publishes. A client sends one JSON request, shuts down its side and reads
-- one reply.
module IDR.Mesh.Netd
  ( Request (..),
    Reply (..),
    unprivileged,
    request,
    requestDown,
    socketPath,
    receiveAll,
    Status (..),
    statusDirectory,
    statusFile,
    appliedRoot,
    appliedDirectory,
    statusVersion,
    desiredVersion,
    pskStatusVersion,
    readStatus,
    upWorkloads,
  )
where

import Control.Exception (Exception (..), bracket, fromException, throwIO)
import Control.Monad (forM, when)
import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes, isJust)
import GHC.Generics (Generic)
import IDR.Mesh.Common
import IDR.Mesh.Desired qualified as D
import IDR.Mesh.Identity (InstanceId, ServiceId)
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.PeerData (Advert)
import IDR.Mesh.Process (ChildStderr (CloseStderr), readProcessBytes)
import IDR.Mesh.PublicKey (PublicKey)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.FilePath (dropExtension, takeExtension, (<.>), (</>))
import System.Timeout (timeout)

data Request
  = Up NS.Workload
  | Down NS.Workload
  | -- Re-apply the stored desired state, for example with changed secrets.
    Apply NS.Workload
  | -- Store and apply the agent's desired state.
    Desired NS.Workload D.Desired
  | -- Assign the mesh address of a registered instance.
    Address NS.Workload InstanceId
  | -- Delete the PSK key stores of workloads that left the inventory.
    Prune
  deriving (Generic)

instance ToJSON Request

instance FromJSON Request

-- The agent may only ask for work that follows from state netd already holds.
unprivileged :: Request -> Bool
unprivileged = \case
  Desired _ _ -> True
  Address _ _ -> True
  Prune -> True
  _ -> False

data Reply = Done | Failed String deriving (Generic)

instance ToJSON Reply

instance FromJSON Reply

socketPath :: FilePath
socketPath = "/run/idr-mesh-netd.sock"

-- netd answered that the request failed.
newtype NetdFailed = NetdFailed String deriving (Show)

instance Exception NetdFailed where
  displayException (NetdFailed message) = message

-- A stopped or hung netd fails the request after a minute.
request :: Request -> IO ()
request r = do
  received <- timeout 60000000 exchange >>= maybe (fail "netd did not answer") pure
  case eitherDecodeStrict' received of
    Right Done -> pure ()
    Right (Failed message) -> throwIO (NetdFailed message)
    Left err -> fail ("Invalid netd reply: " ++ err)
  where
    exchange = bracket (socket AF_UNIX Stream defaultProtocol) close $ \sock -> do
      connect sock (SockAddrUnix socketPath)
      sendAll sock (BL.toStrict (encode r))
      shutdown sock ShutdownSend
      receiveAll sock

-- While netd's socket is being stopped, at shutdown or when the mesh is
-- removed, systemd no longer starts netd. The namespace then stays until /run
-- is cleared at the next boot, which is not a reason to fail the stop. A
-- failure netd reports is one.
requestDown :: NS.Workload -> IO ()
requestDown ns = do
  result <- trySync (request (Down ns))
  case result of
    Right () -> pure ()
    Left err -> do
      let reported = isJust (fromException err :: Maybe NetdFailed)
      (_, jobs) <- readProcessBytes CloseStderr "systemctl" ["list-jobs", "--no-legend", "--plain", "idr-mesh-netd.socket"]
      let stopping = any ((== ["idr-mesh-netd.socket", "stop"]) . take 2 . drop 1 . BC.words) (BC.lines jobs)
      when (reported || not stopping) (throwIO err)
      logLine ("Leaving " ++ NS.serviceName ns ++ " until the next boot, netd is stopping: " ++ describe err)

-- Where netd keeps each workload's applied desired state and PSK status.
appliedRoot :: FilePath
appliedRoot = "/run/idr-mesh-apply"

appliedDirectory :: String -> FilePath
appliedDirectory name = appliedRoot </> name

-- Reads until the other side shuts down its sending side.
receiveAll :: Socket -> IO BS.ByteString
receiveAll sock = BS.concat <$> chunks
  where
    chunks = do
      chunk <- recv sock 65536
      if BS.null chunk then pure [] else (chunk :) <$> chunks

-- What the agent registers for a workload while it is up.
data Status = Status
  { publicKey :: PublicKey,
    port :: Int,
    adverts :: Map ServiceId Advert,
    -- When a PSK switch that waits for its handshake window may proceed, in
    -- seconds since the epoch. netd switches when the agent sends the desired
    -- state again then.
    switchAt :: Maybe Integer
  }
  deriving (Eq, Generic)

instance ToJSON Status

instance FromJSON Status

-- The agent watches this directory for changes.
statusDirectory :: FilePath
statusDirectory = "/run/idr-mesh-netd"

statusFile :: String -> FilePath
statusFile name = statusDirectory </> name <.> "json"

-- Versions of netd's status, applied desired state and PSK status files; see
-- `encodeState`.
statusVersion, desiredVersion, pskStatusVersion :: Int
statusVersion = 1
desiredVersion = 1
pskStatusVersion = 1

-- A status this release cannot read counts as missing until netd publishes it
-- again.
readStatus :: String -> IO (Maybe Status)
readStatus = readState statusVersion . statusFile

-- The workloads that are up, with what netd published for them. An unreadable
-- status leaves out only its own workload.
upWorkloads :: IO [(NS.Workload, Status)]
upWorkloads = do
  files <- listIfPresent statusDirectory
  catMaybes <$> forM files statusOf
  where
    statusOf file = case NS.parseService (dropExtension file) of
      Right ns | takeExtension file == ".json" -> do
        status <- trySync (readStatus (NS.serviceName ns))
        case status of
          Left err -> Nothing <$ logLine (file ++ ": " ++ describe err)
          Right found -> pure ((ns,) <$> found)
      _ -> pure Nothing
