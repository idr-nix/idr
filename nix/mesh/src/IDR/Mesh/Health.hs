{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Health (serve, probe) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently_)
import Control.Monad (forM_, forever, unless, void, when)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.List (find)
import Foreign.C.Error
import GHC.IO.Exception (ioe_errno)
import IDR.Mesh.SocketActivation
import Network.Socket
import Network.Socket.ByteString (recvMsg, sendMsg)
import System.IO.Error (catchIOError)

probe :: BS.ByteString
probe = "idr-mesh-health-v1"

-- Answer probes on the activated UDP sockets of the health port.
serve :: IO ()
serve = withActivatedSockets $ \sockets -> do
  when (null sockets) $ fail "mesh health requires the activated health port sockets"
  mapM_ (requireSocket [AF_INET, AF_INET6] Datagram) sockets
  mapConcurrently_ (\sock -> forever (reply sock `catchIOError` receiveError)) sockets

-- Linux may report an earlier datagram's ICMP error on recvmsg. Back off on
-- that socket while the route is unavailable and let descriptor errors escape.
receiveError :: IOError -> IO ()
receiveError err
  | Just n <- ioe_errno err,
    Errno n `elem` routeErrors =
      threadDelay 10000
  | otherwise = ioError err
  where
    routeErrors =
      [ eCONNREFUSED,
        eHOSTUNREACH,
        eNETUNREACH,
        eHOSTDOWN,
        eNONET,
        eACCES,
        eMSGSIZE,
        eNOPROTOOPT,
        eOPNOTSUPP,
        ePROTO
      ]

reply :: Socket -> IO ()
reply sock = do
  (source, payload, controls, flags) <- recvMsg sock (BS.length probe + 1) 128 mempty
  let truncated = flags .&. (MSG_TRUNC <> MSG_CTRUNC) /= mempty
      packetInfo control = cmsgId control `elem` [CmsgIdIPv4PktInfo, CmsgIdIPv6PktInfo]
  unless (truncated || payload /= probe) $
    -- Reusing the packet info preserves the destination address as the reply source.
    forM_ (find packetInfo controls) $ \info ->
      void (sendMsg sock source [probe] [info] mempty) `catchIOError` const (pure ())
