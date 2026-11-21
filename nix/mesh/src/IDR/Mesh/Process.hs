-- Children get no descriptors beyond stdio, so none holds netd's sockets.
module IDR.Mesh.Process
  ( ChildStderr (..),
    readProcessBytes,
    callChild,
    readChild,
    tryChild,
  )
where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process

data ChildStderr = InheritStderr | CloseStderr deriving (Eq)

-- The child gets no stdin. A cancelled caller kills and reaps it, even one
-- that stalled in NSS.
readProcessBytes :: ChildStderr -> FilePath -> [String] -> IO (ExitCode, ByteString)
readProcessBytes errors program args =
  bracket (createProcess spec) kill $ \(_, out, _, child) -> do
    output <- maybe (fail ("No output pipe for " ++ program)) BS.hGetContents out
    status <- waitForProcess child
    pure (status, output)
  where
    -- A child that was already reaped has no PID left to signal.
    kill (_, out, _, child) = do
      getPid child >>= mapM_ (signalProcess sigKILL)
      _ <- waitForProcess child
      mapM_ hClose out
    spec =
      (closed program args)
        { std_in = NoStream,
          std_out = CreatePipe,
          std_err = if errors == CloseStderr then NoStream else Inherit
        }

-- Fails unless the child succeeds. It writes to the caller's output.
callChild :: FilePath -> [String] -> IO ()
callChild program args = do
  status <- withCreateProcess (closed program args) (\_ _ _ process -> waitForProcess process)
  unless (status == ExitSuccess) $
    fail (unwords (program : args) ++ " failed (" ++ show status ++ ")")

-- The child's standard output; fails unless it succeeds.
readChild :: FilePath -> [String] -> IO String
readChild program args = readCreateProcess (closed program args) ""

-- Feeds the child's standard input and returns its status and both outputs.
tryChild :: FilePath -> [String] -> String -> IO (ExitCode, String, String)
tryChild program args = readCreateProcessWithExitCode (closed program args)

closed :: FilePath -> [String] -> CreateProcess
closed program args = (proc program args) {close_fds = True}
