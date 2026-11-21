module IDR.Mesh.SocketActivation (withActivatedSockets, requireSocket) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Network.Socket
import System.Systemd.Daemon (getActivatedSockets)

withActivatedSockets :: ([Socket] -> IO a) -> IO a
withActivatedSockets = bracket (fromMaybe [] <$> getActivatedSockets) (mapM_ close)

requireSocket :: [Family] -> SocketType -> Socket -> IO ()
requireSocket families kind sock = do
  family <- unpackFamily . fromIntegral <$> getSocketOption sock SoDomain
  socketType <- getSocketType sock
  unless (family `elem` families && socketType == kind) $
    fail ("unexpected activation socket: " ++ show family ++ " " ++ show socketType)
