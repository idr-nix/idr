{-# LANGUAGE OverloadedStrings #-}

-- Peers advertise several addresses, but a WireGuard peer has one endpoint.
-- The prober checks health ports, and the desired state uses the first healthy
-- address.
module IDR.Mesh.Probe (Target (..), probePeers, savedUnhealthy, unhealthyFile, unhealthyVersion) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (forM_, forever, void, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.IP (IP (..), fromHostAddress, fromHostAddress6, toHostAddress, toHostAddress6)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import IDR.Mesh.Common (atomicWrite, describe, encodeState, logLine, readSaved, removeIfExists, trySync)
import IDR.Mesh.Health (probe)
import IDR.Mesh.IP (parseIP)
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendAllTo)

data Target = Target {address :: Text, port :: Int} deriving (Eq, Ord, Generic)

instance ToJSON Target

instance FromJSON Target

-- The unhealthy addresses survive an agent restart, so the first desired state
-- after it keeps the endpoints netd uses.
unhealthyFile :: FilePath
unhealthyFile = "/run/idr-mesh-agent/unhealthy.json"

-- See `encodeState`.
unhealthyVersion :: Int
unhealthyVersion = 1

savedUnhealthy :: IO (Set.Set Target)
savedUnhealthy = fromMaybe Set.empty <$> readSaved unhealthyVersion unhealthyFile

-- Each 5 second round spreads its probes over 4 seconds and then waits for the
-- last replies. An address becomes unhealthy after 3 rounds without a reply and
-- healthy again after one reply. Only peers this host initiates to are probed,
-- each up to its first healthy address, so a steady mesh sends about one probe
-- per peer and round. One socket per address family carries every probe.
-- Each workload publishes, in priority order, the addresses of the peers it
-- initiates to. Unknown addresses count as healthy, so a new peer is usable
-- immediately. The prober starts from the unhealthy set it is given.
probePeers :: TVar (Map.Map String [[Target]]) -> TVar (Set.Set Target) -> IO ()
probePeers targets unhealthy = do
  replies <- newIORef Set.empty
  saved <- readTVarIO unhealthy
  withProbeSocket AF_INET replies $ \v4 -> withProbeSocket AF_INET6 replies $ \v6 -> do
    let loop rounds failures = do
          peers <- concat . Map.elems <$> readTVarIO targets
          let due = Set.toList (Set.fromList (concatMap (untilHealthy failures) peers))
          writeIORef replies Set.empty
          spread (mapM_ (sendProbe v4 v6) . endpointOf) due
          threadDelay 1000000
          answered <- readIORef replies
          -- After a restart, workloads list their addresses within the first
          -- minute. Until then, failures of unlisted addresses are kept.
          let counted = Map.fromList [(t, misses failures answered t) | t <- due]
              unlisted = Map.withoutKeys failures (Set.fromList (concat peers))
              next = if rounds < 12 then counted <> unlisted else counted
          publish (Map.keysSet (Map.filter (>= 3) next))
          loop (rounds + 1 :: Int) next
    loop 0 (Map.fromSet (const 3) saved)
  where
    -- Lower-priority addresses are probed once the ones before them fail, and
    -- a failed preferred address keeps being probed so it can recover.
    untilHealthy failures addresses =
      let (failed, rest) = span (\t -> Map.findWithDefault 0 t failures >= 3) addresses
       in failed ++ take 1 rest
    publish failing = do
      changed <- atomically $ do
        published <- readTVar unhealthy
        when (published /= failing) (writeTVar unhealthy failing)
        pure (published /= failing)
      when changed $ do
        -- The file only carries the state over a restart. One that could not
        -- be updated is removed, so a restart never trusts a stale set.
        saved <- trySync (atomicWrite unhealthyFile (encodeState unhealthyVersion failing))
        either forget pure saved
    forget err = do
      logLine ("Could not save unhealthy addresses: " ++ describe err)
      void (trySync (removeIfExists unhealthyFile))

-- Consecutive rounds without a reply. A reply resets the count.
misses :: Map.Map Target Int -> Set.Set (IP, Int) -> Target -> Int
misses failures answered t
  | any (`Set.member` answered) (endpointOf t) = 0
  | otherwise = Map.findWithDefault 0 t failures + 1

-- Runs the action for each item, spread evenly over four seconds.
spread :: (a -> IO ()) -> [a] -> IO ()
spread _ [] = threadDelay 4000000
spread action items = forM_ items $ \item -> do
  action item
  threadDelay (4000000 `div` length items)

sendProbe :: Maybe Socket -> Maybe Socket -> (IP, Int) -> IO ()
sendProbe v4 v6 (ip, health) = case ip of
  IPv4 a -> send v4 (SockAddrInet port (toHostAddress a))
  IPv6 a -> send v6 (SockAddrInet6 port 0 (toHostAddress6 a) 0)
  where
    port = fromIntegral health
    send sock to = forM_ sock $ \s -> void (trySync (sendAllTo s probe to))

endpointOf :: Target -> Maybe (IP, Int)
endpointOf (Target host health) = (,health) <$> parseIP (T.unpack host)

-- The responder replies from the probed address and port, which identifies the
-- target. IPv4-mapped addresses use the dual-stack IPv6 socket. A family the
-- host cannot open leaves its targets unanswered.
withProbeSocket :: Family -> IORef (Set.Set (IP, Int)) -> (Maybe Socket -> IO a) -> IO a
withProbeSocket family replies use = do
  opened <- trySync (socket family Datagram defaultProtocol)
  case opened of
    Left _ -> use Nothing
    Right sock -> bracket (pure sock) close $ \s -> do
      when (family == AF_INET6) $ setSocketOption s IPv6Only 0
      withAsync (receive s) (const (use (Just s)))
  where
    receive s = forever $ do
      reply <- trySync (recvFrom s 64)
      case reply of
        Right (payload, from) | payload == probe -> forM_ (sourceOf from) record
        Right _ -> pure ()
        Left _ -> threadDelay 10000
    record source = atomicModifyIORef' replies (\set -> (Set.insert source set, ()))
    sourceOf (SockAddrInet p a) = Just (IPv4 (fromHostAddress a), fromIntegral p)
    sourceOf (SockAddrInet6 p _ a _) = Just (IPv6 (fromHostAddress6 a), fromIntegral p)
    sourceOf _ = Nothing
