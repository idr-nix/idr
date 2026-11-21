module IDR.Mesh.Namespace
  ( Workload,
    serviceName,
    parseService,
    Handle (..),
    path,
    runtimeFile,
    available,
    create,
    remove,
    run,
    output,
    json,
    tryRun,
  )
where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..))
import IDR.Mesh.Common (optionalFile, readProcessJson, removeIfExists, touch)
import IDR.Mesh.Process (callChild, readChild, tryChild)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.Exit (ExitCode)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files
  ( createSymbolicLink,
    deviceID,
    getFileStatus,
    getSymbolicLinkStatus,
    isSymbolicLink,
    readSymbolicLink,
    setFileMode,
  )

newtype Workload = Workload {serviceName :: String} deriving (Eq)

parseService :: String -> Either String Workload
parseService name
  | name `notElem` ["", ".", ".."] && '/' `notElem` name && '\0' `notElem` name =
      Right (Workload name)
  | otherwise = Left "Invalid mesh service name"

instance FromJSON Workload where
  parseJSON value = parseJSON value >>= either fail pure . parseService

instance ToJSON Workload where
  toJSON = toJSON . serviceName

-- Namespaces are pinned in root-only runtime directories that only mesh units
-- write, so a pin there is ours. /run/netns gets a symlink for ip-netns users;
-- a name another tool created there is never adopted or removed.
data Handle = Pinned Workload | SharedDns

path :: Handle -> FilePath
path (Pinned ns) = runtimeFile ns "namespace"
path SharedDns = "/run/idr-mesh-dns-netns/namespace"

-- A workload's runtime directory also holds its WireGuard port.
runtimeFile :: Workload -> FilePath -> FilePath
runtimeFile ns name = "/run/idr-mesh-netns" </> serviceName ns </> name

publicName :: Handle -> FilePath
publicName (Pinned ns) = "/run/netns/idr-mesh-" ++ serviceName ns
publicName SharedDns = "/run/netns/idr-dns"

-- An interrupted setup or removal leaves an empty file instead of an nsfs mount.
available :: Handle -> IO Bool
available ns = do
  nsfs <- deviceID <$> getFileStatus "/proc/self/ns/net"
  maybe False ((== nsfs) . deviceID) <$> optionalFile (getFileStatus (path ns))

-- Nothing: no public name. Just True: our symlink.
published :: Handle -> IO (Maybe Bool)
published ns = do
  status <- optionalFile (getSymbolicLinkStatus (publicName ns))
  case status of
    Just s | isSymbolicLink s -> Just . (== path ns) <$> readSymbolicLink (publicName ns)
    other -> pure (False <$ other)

create :: Handle -> IO ()
create ns = do
  pinned <- available ns
  if pinned
    then run ns ["ip", "link", "set", "dev", "lo", "up"]
    else do
      let dir = takeDirectory (path ns)
      present <- doesDirectoryExist dir
      unless present $ createDirectoryIfMissing True dir >> setFileMode dir 0o700
      touch (path ns)
      callChild "unshare" ["--net=" ++ path ns, "ip", "link", "set", "dev", "lo", "up"]
  public <- published ns
  case public of
    Nothing -> do
      -- Match iproute2, which creates /run/netns world-readable.
      createDirectoryIfMissing True "/run/netns"
      setFileMode "/run/netns" 0o755
      createSymbolicLink (path ns) (publicName ns)
    Just True -> pure ()
    Just False -> fail ("Refusing to replace unrelated namespace " ++ publicName ns)

remove :: Handle -> IO ()
remove ns = do
  public <- published ns
  when (public == Just True) $ removeIfExists (publicName ns)
  pinned <- available ns
  when pinned $ callChild "umount" ["--lazy", path ns]
  removeIfExists (path ns)

enter :: Handle -> [String] -> [String]
enter ns command = ["--net=" ++ path ns, "--"] ++ command

run :: Handle -> [String] -> IO ()
run ns = callChild "nsenter" . enter ns

output :: Handle -> [String] -> IO String
output ns command = readChild "nsenter" (enter ns command)

json :: (FromJSON a) => Handle -> [String] -> IO a
json ns = readProcessJson "nsenter" . enter ns

-- Run a command with standard input and return its status and output.
tryRun :: Handle -> [String] -> String -> IO (ExitCode, String, String)
tryRun ns command = tryChild "nsenter" (enter ns command)
