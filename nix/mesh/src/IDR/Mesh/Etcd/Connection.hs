{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module IDR.Mesh.Etcd.Connection
  ( Client,
    clusterId,
    checkCluster,
    Timeouts (..),
    connect,
    withSameCluster,
    unary,
    unaryWith,
    stream,
    retryLeaseStream,
    permissionDenied,
    withWatchProbe,
    expiredWatchReason,
    deadline,
    deadlineMicros,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, cancel, link, mapConcurrently_, waitAnySTM, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
  ( TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    orElse,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Control.Exception
  ( Exception (displayException),
    SomeException,
    bracket,
    catch,
    fromException,
    mask,
    onException,
    throwIO,
    tryJust,
  )
import Control.Monad (forM_, forever, guard, join, mfilter, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.IP (IP (IPv6))
import Data.List (delete, nub, partition)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust, isNothing)
import Data.ProtoLens.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Unique (newUnique)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import IDR.Mesh.Common (readRegularFile)
import IDR.Mesh.Etcd.Config (Server (..))
import IDR.Mesh.Etcd.Types (ClusterId (..))
import IDR.Mesh.IP (numericHostIP, parseHost)
import IDR.Mesh.Port (parsePort)
import IDR.Mesh.Process (ChildStderr (CloseStderr), readProcessBytes)
import Network.GRPC.Client qualified as G
import Network.GRPC.Common
import Network.GRPC.Common.Protobuf
import Network.HTTP2.Client qualified as H2
import Network.TLS (TLSError (Error_EOF, Error_TCP_Terminate), TLSException (..))
import Network.URI (URI (..), URIAuth (..), parseURI, unEscapeString)
import Proto.API.Etcd qualified as P
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Error (isPermissionError, isUserError, tryIOError)
import System.ThreadManager (KilledByThreadManager (..))
import System.Timeout (timeout)

-- etcd returns a bearer token from Authenticate and expects it in the
-- "token" metadata header on subsequent unary and streaming calls.
newtype Token = Token (Maybe BS.ByteString) deriving (Eq)

instance Show Token where
  show _ = "<etcd credentials>"

instance Default Token where
  def = Token Nothing

instance BuildMetadata Token where
  buildMetadata (Token value) = [CustomMetadata "token" token | Just token <- [value]]

-- Match clientv3.WithRequireLeader for Watch and LeaseKeepAlive: a member
-- that loses its Raft leader must terminate these long-lived streams.
newtype StreamHeaders = WithRequireLeader Token deriving (Show)

instance Default StreamHeaders where
  def = WithRequireLeader def

instance BuildMetadata StreamHeaders where
  buildMetadata (WithRequireLeader token) =
    CustomMetadata "hasleader" "true" : buildMetadata token

data Headers = Headers deriving (Show)

instance ParseMetadata Headers where
  parseMetadata _ = pure Headers

type instance RequestMetadata (Protobuf P.Auth method) = Token

type instance RequestMetadata (Protobuf P.KV method) = Token

type instance RequestMetadata (Protobuf P.Lease "leaseGrant") = Token

type instance RequestMetadata (Protobuf P.Lease "leaseRevoke") = Token

type instance RequestMetadata (Protobuf P.Lease "leaseKeepAlive") = StreamHeaders

type instance RequestMetadata (Protobuf P.Watch method) = StreamHeaders

type instance RequestMetadata (Protobuf P.Maintenance "status") = Token

type instance ResponseInitialMetadata (Protobuf P.Auth method) = Headers

type instance ResponseInitialMetadata (Protobuf P.KV method) = Headers

type instance ResponseInitialMetadata (Protobuf P.Lease method) = Headers

type instance ResponseInitialMetadata (Protobuf P.Watch method) = Headers

type instance ResponseInitialMetadata (Protobuf P.Maintenance "status") = Headers

type instance ResponseTrailingMetadata (Protobuf P.Auth method) = Headers

type instance ResponseTrailingMetadata (Protobuf P.KV method) = Headers

type instance ResponseTrailingMetadata (Protobuf P.Lease method) = Headers

type instance ResponseTrailingMetadata (Protobuf P.Watch method) = Headers

type instance ResponseTrailingMetadata (Protobuf P.Maintenance "status") = Headers

data Client = Client
  { connection :: G.Connection,
    endpoint :: Endpoint,
    selectedAddress :: String,
    clusterId :: ClusterId,
    currentToken :: MVar Token,
    authenticate :: Login,
    timeouts :: Timeouts
  }

type Login = Maybe ClusterId -> IO () -> G.Connection -> IO (ClusterId, Token)

data DifferentCluster = DifferentCluster deriving (Show)

instance Exception DifferentCluster where
  displayException _ = "etcd endpoint belongs to a different cluster"

responseCluster :: Maybe ClusterId -> Maybe P.ResponseHeader -> IO ClusterId
responseCluster expected header = do
  let missing = fail "etcd response is missing its cluster header"
  actual <- maybe missing (pure . ClusterId . (^. #clusterId)) header
  forM_ expected $ \cluster -> unless (actual == cluster) $ throwIO DifferentCluster
  pure actual

checkCluster :: Client -> Maybe P.ResponseHeader -> IO ()
checkCluster client = void . responseCluster (Just (clusterId client))

data Timeouts = Timeouts {commandSeconds, transactionSeconds :: Int}

connect :: Timeouts -> Maybe ClusterId -> Server -> (Client -> IO a) -> IO a
connect limits expected (Server url username passwordFile) use = do
  target <- maybe (fail "Expected a single HTTP or HTTPS etcd endpoint") pure (parseServer url)
  login <- authenticateWith (commandSeconds limits) username passwordFile
  route <- makeEndpoint target
  withAuthenticated limits route expected Nothing login use

authenticateWith :: Int -> String -> FilePath -> IO Login
authenticateWith seconds username passwordFile = do
  -- Unusable credentials fail the connection at once. Each login reads the
  -- file again, so a new password applies without a restart.
  _ <- credentials
  pure $ \expected beforeSend channel -> do
    request <- credentials
    -- Auth-enabled etcd requires a user for Maintenance.Status. An empty
    -- transaction reads and writes no keys and returns the member's cluster
    -- header before we disclose the password on this channel.
    when (isJust expected) $ do
      let method = Proxy @(Protobuf P.KV "txn")
      probe <- unaryRPC beforeSend channel seconds def method defMessage
      void $ responseCluster expected (getProto probe ^. #maybe'header)
    let method = Proxy @(Protobuf P.Auth "authenticate")
    response <- unaryRPC beforeSend channel seconds def method request
    cluster <- responseCluster expected (getProto response ^. #maybe'header)
    let token = response ^. #token
    when (T.null token) $ fail "etcd returned an empty authentication token"
    pure (cluster, Token (Just (T.encodeUtf8 token)))
  where
    credentials = do
      bytes <- BS.dropWhileEnd (\c -> c == 10 || c == 13) <$> readRegularFile passwordFile
      password <- either (const $ fail "Invalid etcd password encoding") pure (T.decodeUtf8' bytes)
      when (null username || T.null password || T.any (== '\0') password) $
        fail "Invalid etcd credentials"
      pure (defMessage & #name .~ T.pack username & #password .~ password)

-- grpc-proxy can preserve an upstream etcd error's description while
-- reporting UNKNOWN as its status. Only match the specific server error.
etcdError :: GrpcException -> GrpcError -> T.Text -> Bool
etcdError err code message =
  grpcError err `elem` [code, GrpcUnknown] && grpcErrorMessage err == Just message

data Target = Target {targetHost :: String, serverAt :: String -> G.Server}

parseServer :: String -> Maybe Target
parseServer url = do
  uri <- parseURI url
  auth <- uriAuthority uri
  guard (null (uriUserInfo auth))
  guard (uriPath uri `elem` ["", "/"] && null (uriQuery uri) && null (uriFragment uri))
  (dialHost, name, authorityHost) <- case uriRegName auth of
    '[' : rest -> do
      -- The URI parser accepts an IPv6 zone as %25 followed by a ZoneID.
      -- Only the local socket needs the decoded interface name or index.
      let dial = unEscapeString (takeWhile (/= ']') rest)
          address = takeWhile (/= '%') dial
      IPv6 _ <- numericHostIP dial
      pure (dial, address, "[" ++ address ++ "]")
    host -> (host, host, host) <$ parseHost host
  -- Direct HTTPS is intentionally best-effort; the local proxy is the normal
  -- path. Stock grapesy verifies against the system store and the authority,
  -- so the HTTPS authority carries no port.
  let secure = G.ServerSecure (G.ValidateServer G.certStoreFromSystem) SslKeyLogNone
  (defaultPort, makeServer, authority) <- case uriScheme uri of
    "http:" -> Just (80, G.ServerInsecure, authorityHost ++ uriPort auth)
    "https:" -> Just (443, secure, name)
    _ -> Nothing
  port <- case uriPort auth of
    "" -> Just defaultPort
    ':' : value -> either (const Nothing) Just (parsePort value)
    _ -> Nothing
  let server ip = makeServer (G.Address ip (fromIntegral port) (Just authority))
  pure (Target dialHost server)

-- Only the dial host is resolved again. HTTP/2 and TLS keep the configured
-- name when the endpoint changes address.
data Endpoint = Endpoint
  { dialHost :: String,
    atAddress :: String -> G.Server,
    knownAddresses :: TVar (Maybe DnsAnswer)
  }

data DnsAnswer = DnsAnswer
  { lookupStarted :: Word64,
    validUntil :: Word64,
    advertised :: [String],
    preferred :: Maybe String
  }

makeEndpoint :: Target -> IO Endpoint
makeEndpoint target = Endpoint (targetHost target) (serverAt target) <$> newTVarIO Nothing

resolve :: String -> IO [String]
resolve host = do
  -- NSS modules may block inside libc beyond a Haskell timeout. Run the
  -- system lookup in a child so cancellation can kill and reap it.
  let arguments = ["--no-addrconfig", "--", "ahosts", host]
  (status, bytes) <- readProcessBytes CloseStderr "/usr/bin/getent" arguments
  unless (status == ExitSuccess) $ fail "Could not resolve etcd endpoint"
  let addrs =
        [ addr
        | line <- B8.lines bytes,
          raw : "STREAM" : _ <- [B8.words line],
          let addr = B8.unpack raw,
          isJust (numericHostIP addr)
        ]
  when (null addrs) $ fail "etcd endpoint has no addresses"
  pure (nub addrs)

-- Race only dial, TLS and Authenticate. The application runs once, after
-- losing connections close. A pinned quorum probe uses exactly its watch's IP.
withAuthenticated ::
  Timeouts -> Endpoint -> Maybe ClusterId -> Maybe String -> Login -> (Client -> IO a) -> IO a
withAuthenticated limits route expected pinned login use =
  bracket (newIORef []) closeAll $ \opened -> do
    let dial address = mask $ \restore -> do
          -- Replacing a socket requires a fresh login and cluster check.
          -- A dropped transaction must return to its owner for reconciliation.
          let verify = requireAddress route address
              dialParams = def {G.connReconnectPolicy = G.ReconnectPolicy (pure G.DontReconnect)}
          channel <- G.openConnection dialParams (atAddress route address)
          credential <-
            restore (login expected verify channel) `onException` G.closeConnection channel
          key <- newUnique
          atomicModifyIORef' opened (\cs -> ((key, channel) : cs, ()))
          pure (key, address, channel, credential)
    (winner, address, conn, (cluster, token)) <-
      deadline (commandSeconds limits) $
        selectAddress (commandSeconds limits) route pinned dial
    losers <- filter ((/= winner) . fst) <$> readIORef opened
    mapConcurrently_ (G.closeConnection . snd) losers
    writeIORef opened [(winner, conn)]
    credential <- newMVar token
    use (Client conn route address cluster credential login limits)
  where
    closeAll opened = readIORef opened >>= mapConcurrently_ (G.closeConnection . snd)

-- getent supplies no TTL. Only a successful NSS answer grants another five
-- seconds of fallback during resolver trouble. Concurrent lookups can finish
-- out of order, so an older query cannot undo a newer successful answer.
refreshAddresses :: Endpoint -> IO ()
refreshAddresses route = do
  started <- getMonotonicTimeNSec
  ips <- resolve (dialHost route)
  now <- getMonotonicTimeNSec
  atomically $ modifyTVar' (knownAddresses route) $ \old ->
    let kept = mfilter (`elem` ips) (old >>= preferred)
     in if maybe False ((> started) . lookupStarted) old
          then old
          else Just (DnsAnswer started (now + 5000000000) ips kept)

advertises :: Word64 -> String -> DnsAnswer -> Bool
advertises now ip answer = now < validUntil answer && ip `elem` advertised answer

validAt :: Word64 -> DnsAnswer -> Bool
validAt now = (> now) . validUntil

unavailable :: T.Text -> GrpcException
unavailable message = GrpcException GrpcUnavailable (Just message) Nothing []

addressUnavailable :: GrpcException
addressUnavailable = unavailable "etcd dial address is no longer advertised"

-- TCP, TLS or HTTP/2 startup may have waited across a DNS change. Check the
-- shared answer immediately before sending the initial login.
requireAddress :: Endpoint -> String -> IO ()
requireAddress route ip =
  when (isNothing (numericHostIP (dialHost route))) $ do
    now <- getMonotonicTimeNSec
    known <- readTVarIO (knownAddresses route)
    unless (maybe False (advertises now ip) known) $ throwIO addressUnavailable

-- A login in flight to one address, and its outcome.
type Dial a = Async (String, Either SomeException a)

-- Races logins to the advertised addresses, staggered, and returns the first
-- that succeeds while its address is still advertised. That address becomes
-- the preferred one.
selectAddress :: Int -> Endpoint -> Maybe String -> (String -> IO a) -> IO a
selectAddress seconds route pinned dial
  | isJust (numericHostIP host) = dial host
  | otherwise = do
      start <- getMonotonicTimeNSec
      known <- readTVarIO cache
      let end = start + fromIntegral seconds * 1000000000
      withResolver route (acquire end (isJust known && isNothing pinned) [] [] 0)
  where
    host = dialHost route
    cache = knownAddresses route
    attempt ip = (ip,) <$> tryJust (\e -> e <$ guard (candidateUnavailable e)) (dial ip)
    without ip = filter ((/= ip) . fst)

    acquire end retryUnavailable live failed nextDial = do
      now <- getMonotonicTimeNSec
      when (now >= end) $ throwIO rpcTimedOut
      known <- readTVarIO cache
      let again = acquire end retryUnavailable
      case mfilter (validAt now) known of
        Nothing -> do
          mapConcurrently_ (cancel . snd) live
          atomically $ readTVar cache >>= check . maybe False (validAt now)
          again [] [] 0
        Just answer -> do
          candidates <- either throwIO pure (candidatesFor pinned answer)
          -- Preserve an in-flight login while its address is still advertised,
          -- even when another address appears, disappears or changes order.
          let retained ip = ip `elem` candidates
              (active, removed) = partition (retained . fst) live
              errors = filter (retained . fst) failed
              tried = map fst active ++ map fst errors
              untried = filter (`notElem` tried) (NE.toList candidates)
              stagger = min 250000000 ((end - now) `div` (2 * fromIntegral (NE.length candidates)))
          mapConcurrently_ (cancel . snd) removed
          case (untried, active, errors) of
            (ip : _, _, _) | null active || now >= nextDial -> do
              withAsync (attempt ip) $ \worker ->
                again ((ip, worker) : active) errors (now + stagger)
            ([], [], (_, err) : _)
              | retryUnavailable -> threadDelay 250000 >> again [] [] 0
              | otherwise -> throwIO err
            _ -> do
              -- Wake for the next candidate, a DNS replacement/expiry, or a
              -- completed login. Failed dials release the next one immediately.
              let expiry = validUntil answer
                  wake = if null untried then expiry else min nextDial expiry
              event <- awaitDial cache answer (wake - now) (map snd active)
              case event of
                Just (ip, Left err) -> again (without ip active) ((ip, err) : errors) 0
                Just (ip, Right value) -> do
                  accepted <- prefer cache ip
                  if accepted then pure value else again (without ip active) errors 0
                Nothing -> again active errors nextDial

-- Resolves the endpoint every half second while the action runs. Starts NSS
-- first. If it stalls, a recent answer can still renew a lease. With no usable
-- answer, the action waits for the lookup itself.
withResolver :: Endpoint -> IO a -> IO a
withResolver route action = do
  first <- newEmptyMVar
  let refresh = forever $ do
        outcome <- tryIOError (refreshAddresses route)
        void $ tryPutMVar first outcome
        threadDelay 500000
  withAsync refresh $ \resolver -> do
    link resolver
    initial <- timeout 250000 (readMVar first)
    now <- getMonotonicTimeNSec
    available <- readTVarIO (knownAddresses route)
    case initial of
      Just (Left err) | not (maybe False (validAt now) available) -> throwIO err
      _ -> action

-- The pinned address, or every advertised one with the preferred one first.
candidatesFor :: Maybe String -> DnsAnswer -> Either GrpcException (NonEmpty String)
candidatesFor pinned answer = do
  let noAddresses = unavailable "etcd endpoint has no addresses"
  addresses <- maybe (Left noAddresses) Right (NE.nonEmpty (advertised answer))
  case pinned of
    Just ip | ip `notElem` addresses -> Left addressUnavailable
    Just ip -> Right (ip :| [])
    Nothing -> Right (maybe addresses (`first` addresses) (preferred answer))
  where
    first ip addresses = ip :| delete ip (NE.toList addresses)

-- Waits up to the given nanoseconds for a finished dial. A newer DNS answer
-- ends the wait early with nothing.
awaitDial ::
  TVar (Maybe DnsAnswer) ->
  DnsAnswer ->
  Word64 ->
  [Dial a] ->
  IO (Maybe (String, Either SomeException a))
awaitDial cache answer nanos dials =
  join <$> timeout (fromIntegral (nanos `div` 1000)) (atomically (replaced `orElse` finished))
  where
    replaced = do
      latest <- readTVar cache
      check (maybe False ((> lookupStarted answer) . lookupStarted) latest)
      pure Nothing
    finished = Just . snd <$> waitAnySTM dials

-- Accepts a finished login only while its address is still advertised, and
-- makes that address the preferred one.
prefer :: TVar (Maybe DnsAnswer) -> String -> IO Bool
prefer cache ip = do
  finished <- getMonotonicTimeNSec
  atomically $ do
    latest <- readTVar cache
    case latest of
      Just current | advertises finished ip current -> do
        writeTVar cache (Just current {preferred = Just ip})
        pure True
      _ -> pure False

-- An address can accept TCP but return an availability error from Authenticate.
-- The shared deadline bounds candidates whose own RPC times out early.
candidateUnavailable :: SomeException -> Bool
candidateUnavailable cause
  | Just DifferentCluster <- fromException cause = True
  | Just err <- fromException cause = grpcError err `elem` [GrpcUnavailable, GrpcDeadlineExceeded]
  | Just err <- fromException cause = not (isUserError err || isPermissionError err)
  | Just err <- fromException cause = case err of
      HandshakeFailed reason -> closed reason
      PostHandshake reason -> closed reason
      Terminated _ _ reason -> closed reason
      Uncontextualized reason -> closed reason
      _ -> False
  | Just (G.ServerDisconnected inner _) <- fromException cause = wrapped inner
  | otherwise = case fromException cause of
      Just H2.ConnectionIsClosed -> True
      Just H2.ConnectionIsTimeout -> True
      Just (H2.BadThingHappen inner) -> wrapped inner
      Just (H2.ConnectionErrorIsReceived code _ _) ->
        code `elem` [H2.NoError, H2.SettingsTimeout, H2.ConnectError]
      Just (H2.StreamErrorIsReceived H2.RefusedStream _) -> True
      _ -> False
  where
    closed reason = reason `elem` [Error_EOF, Error_TCP_Terminate]
    wrapped inner = case fromException inner of
      Just (KilledByThreadManager (Just original)) -> candidateUnavailable original
      _ -> candidateUnavailable inner

deadline :: Int -> IO a -> IO a
deadline seconds = deadlineMicros (seconds * 1000000)

deadlineMicros :: Int -> IO a -> IO a
deadlineMicros micros action = timeout micros action >>= maybe (throwIO rpcTimedOut) pure

rpcTimedOut :: GrpcException
rpcTimedOut = GrpcException GrpcDeadlineExceeded (Just "etcd RPC timed out") Nothing []

unaryRPC ::
  (SupportsClientRpc rpc, RequestMetadata rpc ~ Token) =>
  IO () -> G.Connection -> Int -> Token -> Proxy rpc -> Input rpc -> IO (Output rpc)
unaryRPC beforeSend conn seconds token method input =
  G.withRPC conn params method $ \call -> do
    beforeSend
    G.sendFinalInput call input
    fst <$> G.recvFinalOutput call
  where
    params =
      def
        { G.callRequestMetadata = token,
          G.callTimeout = Just (G.Timeout G.Second (G.TimeoutValue (fromIntegral seconds)))
        }

-- Retry only explicit authentication rejections. A disconnected transaction
-- may already have committed, so its caller must reconcile the result.
unary ::
  (SupportsClientRpc rpc, RequestMetadata rpc ~ Token) =>
  Client -> Proxy rpc -> Input rpc -> IO (Output rpc)
unary = unaryWith commandSeconds

unaryWith ::
  (SupportsClientRpc rpc, RequestMetadata rpc ~ Token) =>
  (Timeouts -> Int) -> Client -> Proxy rpc -> Input rpc -> IO (Output rpc)
unaryWith budget client method input = deadline seconds $ do
  token <- readMVar (currentToken client)
  let call credential = unaryRPC (pure ()) (connection client) seconds credential method input
  call token `catch` \err -> do
    unless (staleToken err) $ throwIO err
    -- Concurrent callers that saw the same stale token log in once.
    updated <- modifyMVar (currentToken client) $ \current -> do
      fresh <- if current == token then login else pure current
      pure (fresh, fresh)
    call updated
  where
    seconds = budget (timeouts client)
    login = snd <$> authenticate client (Just (clusterId client)) (pure ()) (connection client)

staleTokenErrors :: [(GrpcError, T.Text)]
staleTokenErrors =
  [ (GrpcUnauthenticated, "etcdserver: invalid auth token"),
    (GrpcInvalidArgument, "etcdserver: revision of auth store is old"),
    (GrpcInvalidArgument, "etcdserver: user name is empty")
  ]

-- etcd refused the request under the user's roles, so nothing was written.
-- The gRPC proxy reports it with code Unknown.
permissionDenied :: SomeException -> Bool
permissionDenied cause = case fromException cause of
  Just err -> etcdError err GrpcPermissionDenied "etcdserver: permission denied"
  Nothing -> False

staleToken :: GrpcException -> Bool
staleToken err = any (uncurry (etcdError err)) staleTokenErrors

-- A renewal is idempotent for one lease. A remote stream cancellation
-- (including grpc-proxy losing its upstream) can also be resumed.
retryLeaseStream :: SomeException -> Maybe ()
retryLeaseStream cause =
  guard $
    candidateUnavailable cause || case fromException cause of
      Just err -> staleToken err || grpcError err == GrpcCancelled
      Nothing -> case fromException cause of
        Just (ProtocolException TooFewOutputs {}) -> True
        _ -> False

-- etcd returns a gRPC status string in a rejected WatchCreate response.
-- grpc-proxy returns just the etcd error description in the same field.
expiredWatchReason :: T.Text -> Bool
expiredWatchReason reason =
  status `elem` prefixes && any ((== message) . snd) staleTokenErrors
  where
    (status, message) = T.breakOnEnd " desc = " reason
    prefixes =
      [ "",
        "rpc error: code = Unauthenticated desc = ",
        "rpc error: code = InvalidArgument desc = "
      ]

-- A watch can use the primary for quorum probes when both connections reached
-- the same address. After stream failover, probe that stream's selected route.
data WatchProbe = PrimaryProbe Client | PinnedProbe Client

withWatchProbe :: WatchProbe -> (Client -> IO a) -> IO a
withWatchProbe (PrimaryProbe primary) use = use primary
withWatchProbe (PinnedProbe selected) use =
  reconnect selected (Just (selectedAddress selected)) use

-- Each new socket must prove membership of the original client's cluster.
withSameCluster :: Client -> (Client -> IO a) -> IO a
withSameCluster client = reconnect client Nothing

reconnect :: Client -> Maybe String -> (Client -> IO a) -> IO a
reconnect client pinned =
  withAuthenticated limits (endpoint client) (Just (clusterId client)) pinned (authenticate client)
  where
    limits = timeouts client

stream ::
  (SupportsClientRpc rpc, RequestMetadata rpc ~ StreamHeaders) =>
  Client -> Proxy rpc -> (WatchProbe -> G.Call rpc -> IO a) -> IO a
stream client method use =
  withSameCluster client $ \streamClient -> do
    token <- readMVar (currentToken streamClient)
    let probe
          | selectedAddress client == selectedAddress streamClient = PrimaryProbe client
          | otherwise = PinnedProbe streamClient
        params = def {G.callRequestMetadata = WithRequireLeader token}
    G.withRPC (connection streamClient) params method (use probe)
