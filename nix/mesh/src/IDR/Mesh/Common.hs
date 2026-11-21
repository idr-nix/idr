{-# LANGUAGE OverloadedStrings #-}

module IDR.Mesh.Common
  ( atomicWrite,
    atomicWritePrivate,
    atomicWriteWithMode,
    durableWrite,
    syncPath,
    optionalFile,
    listIfPresent,
    readOptionalFile,
    readRegularFile,
    removeIfExists,
    touch,
    readJson,
    readOptionalJson,
    encodeState,
    readState,
    readStateWith,
    readSaved,
    decodeJson,
    readProcessJson,
    withLock,
    Locks,
    newLocks,
    withNamedLock,
    trySync,
    describe,
    logLine,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception
  ( Exception (displayException),
    SomeAsyncException,
    SomeException (..),
    bracket,
    bracketOnError,
    finally,
    fromException,
    tryJust,
  )
import Control.Monad (unless, when)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeStrict', encode, object, parseJSON, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import IDR.Mesh.FileMode (setAccessMode)
import IDR.Mesh.Process (ChildStderr (InheritStderr), readProcessBytes)
import Numeric (showHex)
import System.Directory (listDirectory, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FileLock (SharedExclusive (Exclusive), withFileLock)
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, stderr)
import System.IO.Error (catchIOError, isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
import System.Posix.IO
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)
import System.Random (randomIO)

trySync :: IO a -> IO (Either SomeException a)
trySync = tryJust $ \e ->
  if isNothing (fromException e :: Maybe SomeAsyncException) then Just e else Nothing

optionalFile :: IO a -> IO (Maybe a)
optionalFile action =
  (Just <$> action) `catchIOError` \err ->
    if isDoesNotExistError err then pure Nothing else ioError err

listIfPresent :: FilePath -> IO [FilePath]
listIfPresent dir = fromMaybe [] <$> optionalFile (listDirectory dir)

removeIfExists :: FilePath -> IO ()
removeIfExists path =
  removeFile path `catchIOError` \err -> unless (isDoesNotExistError err) $ do
    -- Linux can return EROFS even for a missing marker on a read-only mount.
    entry <- optionalFile (getSymbolicLinkStatus path)
    when (isJust entry) (ioError err)

touch :: FilePath -> IO ()
touch path =
  bracket
    (openFd path WriteOnly defaultFileFlags {creat = Just 0o666, cloexec = True, nofollow = True})
    closeFd
    touchFd

-- Open without following a symlink. O_NONBLOCK lets us reject a FIFO before
-- reading it, even when there is no writer on the other end.
readOptionalFile :: FilePath -> IO (Maybe ByteString)
readOptionalFile = optionalFile . readRegular True

-- Configured credential paths may be symlinks to versioned secrets.
readRegularFile :: FilePath -> IO ByteString
readRegularFile = readRegular False

readRegular :: Bool -> FilePath -> IO ByteString
readRegular noFollow path = do
  let flags = defaultFileFlags {cloexec = True, nofollow = noFollow, nonBlock = True}
      openRegular = bracketOnError (openFd path ReadOnly flags) closeFd $ \fd -> do
        status <- getFdStatus fd
        unless (isRegularFile status) $ fail ("Expected a regular file at " ++ path)
        fdToHandle fd
  bracket openRegular hClose BS.hGetContents

-- The replacement lives on the same filesystem as the destination. Existing
-- readers keep the old inode, while new readers see the complete new file.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite = writeReplacing False Nothing

atomicWritePrivate :: FilePath -> ByteString -> IO ()
atomicWritePrivate = atomicWriteWithMode 0o600

atomicWriteWithMode :: FileMode -> FilePath -> ByteString -> IO ()
atomicWriteWithMode = writeReplacing False . Just

-- An atomic replacement that also survives a crash: the data reaches the disk
-- before the rename, and the rename before this returns.
durableWrite :: Maybe FileMode -> FilePath -> ByteString -> IO ()
durableWrite mode path contents = do
  writeReplacing True mode path contents
  syncPath (takeDirectory path)

writeReplacing :: Bool -> Maybe FileMode -> FilePath -> ByteString -> IO ()
writeReplacing durable mode path contents =
  bracket (optionalFile (openFd path ReadOnly flags)) (mapM_ closeFd) $ \source -> do
    previous <- traverse getFdStatus source
    for_ previous $ \status ->
      unless (isRegularFile status) $
        fail ("Expected a regular file at " ++ path)
    let newMode = if isJust mode || isJust previous then 0o600 else 0o666
        temporary = newTemporary (takeDirectory path) newMode
        open = bracketOnError temporary (discard closeFd) $ \(name, fd) -> do
          handle <- fdToHandle fd
          pure (name, handle)
        permissions fd = do
          for_ previous $ \old -> do
            fresh <- getFdStatus fd
            when (fileOwner fresh /= fileOwner old || fileGroup fresh /= fileGroup old) $
              setFdOwnerAndGroup fd (fileOwner old) (fileGroup old)
          case (mode, previous) of
            (Just bits, _) -> setAccessMode Nothing fd bits
            (_, Just old) -> setAccessMode source fd (fileMode old .&. 0o7777)
            _ -> pure ()
    bracketOnError open (discard hClose) $ \(name, handle) -> do
      BS.hPut handle contents
      -- Converting back to an fd flushes the data before restoring ownership,
      -- access ACL and mode. A write could otherwise clear set-id bits.
      bracket (handleToFd handle) closeFd $ \fd ->
        permissions fd >> when durable (fileSynchronise fd)
      renameFile name path
  where
    flags = defaultFileFlags {cloexec = True, nofollow = True, nonBlock = True}
    discard close (name, resource) = close resource `finally` removeIfExists name

newTemporary :: FilePath -> FileMode -> IO (FilePath, Fd)
newTemporary dir mode = do
  suffix <- randomIO :: IO Word64
  let name = dir </> (".idr-save-" ++ showHex suffix "")
      flags = defaultFileFlags {exclusive = True, cloexec = True, creat = Just mode}
      create = (,) name <$> openFd name WriteOnly flags
  create `catchIOError` \err ->
    if isAlreadyExistsError err then newTemporary dir mode else ioError err

-- For a durable replacement, sync the file and its containing directory.
syncPath :: FilePath -> IO ()
syncPath path =
  bracket (openFd path ReadOnly defaultFileFlags {cloexec = True}) closeFd fileSynchronise

readJson :: (FromJSON a) => FilePath -> IO a
readJson path = BS.readFile path >>= decodeJson path

readOptionalJson :: (FromJSON a) => FilePath -> IO (Maybe a)
readOptionalJson path = readOptionalFile path >>= traverse (decodeJson path)

-- Every state file the mesh writes is {"version": n, "state": ...}. A release
-- that changes a file's format bumps that file's version. A file of another
-- version, including one a newer release wrote before a rollback, counts as
-- missing and is written again, so upgrades and rollbacks need no migration.
encodeState :: (ToJSON a) => Int -> a -> ByteString
encodeState version state =
  BL.toStrict (encode (object ["version" .= version, "state" .= state])) <> "\n"

readState :: (FromJSON a) => Int -> FilePath -> IO (Maybe a)
readState version = readStateWith version parseJSON

-- A malformed file or one of another version counts as missing and is logged.
readStateWith :: Int -> (Value -> Parser a) -> FilePath -> IO (Maybe a)
readStateWith version parser path = readOptionalFile path >>= maybe (pure Nothing) decode'
  where
    decode' bytes = case eitherDecodeStrict' bytes >>= parseEither envelope of
      Right state -> pure (Just state)
      Left reason -> Nothing <$ logLine (path ++ ": ignored: " ++ reason)
    envelope = withObject "mesh state" $ \o -> do
      found <- o .: "version"
      unless (found == version) $
        fail ("version " ++ show (found :: Int) ++ ", expected " ++ show version)
      o .: "state" >>= parser

-- State carried over a restart. A file that cannot be read counts as missing.
readSaved :: (FromJSON a) => Int -> FilePath -> IO (Maybe a)
readSaved version path = either (const Nothing) id <$> trySync (readState version path)

decodeJson :: (FromJSON a) => String -> ByteString -> IO a
decodeJson source = either (fail . ((source ++ ": ") ++)) pure . eitherDecodeStrict'

readProcessJson :: (FromJSON a) => FilePath -> [String] -> IO a
readProcessJson program args = do
  (status, raw) <- readProcessBytes InheritStderr program args
  let command = unwords (program : args)
  unless (status == ExitSuccess) $ fail (command ++ " exited with " ++ show status)
  decodeJson command raw

withLock :: FilePath -> IO a -> IO a
withLock path = withFileLock path Exclusive . const

-- One in-process lock per name, created on first use.
newtype Locks = Locks (MVar (Map String (MVar ())))

newLocks :: IO Locks
newLocks = Locks <$> newMVar Map.empty

withNamedLock :: Locks -> String -> IO a -> IO a
withNamedLock (Locks locks) name action = do
  lock <- modifyMVar locks $ \held -> case Map.lookup name held of
    Just lock -> pure (held, lock)
    Nothing -> do
      lock <- newMVar ()
      pure (Map.insert name lock held, lock)
  withMVar lock (const action)

-- The exception's own message, without the backtrace GHC attaches.
describe :: SomeException -> String
describe (SomeException e) = displayException e

-- Each message is written at once, so concurrent threads don't interleave.
logLine :: String -> IO ()
logLine message = BS.hPut stderr (TE.encodeUtf8 (T.pack (message ++ "\n")))
