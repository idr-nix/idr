{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The etcd v3 operations used by registration, discovery and PSK rotation.
module IDR.Mesh.Etcd
  ( Client,
    ClusterId,
    clusterId,
    withMeshEtcd,
    withSameCluster,
    Revision,
    LeaseId,
    Entry (..),
    Compare (..),
    Change (..),
    Reads,
    point,
    prefix,
    readSnapshot,
    readPoint,
    readPrefix,
    transaction,
    permissionDenied,
    Lease,
    leaseId,
    leaseTTL,
    grant,
    revoke,
    revokeLease,
    keepAlive,
    watch,
  )
where

import Control.Concurrent
  ( MVar,
    newEmptyMVar,
    putMVar,
    takeMVar,
    threadDelay,
    tryPutMVar,
    tryTakeMVar,
  )
import Control.Concurrent.Async (concurrently, race_, wait, withAsync)
import Control.Exception (Exception (displayException), catch, catchJust, throwIO)
import Control.Monad (forever, replicateM, unless, void, when, zipWithM)
import Control.Monad.Trans.State.Strict (StateT (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.List (uncons)
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe)
import Data.Monoid (Endo (..))
import Data.ProtoLens.Labels ()
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import IDR.Mesh.Etcd.Config (Server)
import IDR.Mesh.Etcd.Connection
import IDR.Mesh.Etcd.Types
import Network.GRPC.Client qualified as G
import Network.GRPC.Common.Protobuf
import Proto.API.Etcd qualified as P
import System.Timeout (timeout)

-- Registration and discovery allow 30 seconds per transaction.
-- Authentication, point reads, quorum probes and leases use the command limit.
agentTimeouts :: Timeouts
agentTimeouts = Timeouts {commandSeconds = 10, transactionSeconds = 30}

-- The agent uses whichever cluster its endpoint reaches, so pointing the
-- endpoint at another cluster moves the mesh there. A connection stays on the
-- cluster it first authenticated to.
withMeshEtcd :: Server -> (Client -> IO a) -> IO a
withMeshEtcd = connect agentTimeouts Nothing

data Entry = Entry
  { entryKey :: Text,
    entryValue :: ByteString,
    entryRevision :: Revision,
    entryLease :: Maybe LeaseId
  }
  deriving (Eq, Show)

data Range = Key Text | Prefix Text deriving (Eq, Show)

data Compare = Missing Text | Modified Text Revision deriving (Eq, Show)

data Change = Put Text ByteString (Maybe LeaseId) | Delete Text deriving (Eq, Show)

-- Prefix scans and watches both use etcd's half-open byte range. The
-- all-zero sentinel means there is no upper bound.
bounds :: Range -> (ByteString, ByteString)
bounds (Key key) = (T.encodeUtf8 key, BS.empty)
bounds (Prefix key)
  | BS.null start = ("\0", "\0")
  | otherwise = (start, end)
  where
    start = T.encodeUtf8 key
    end = case BS.unsnoc (BS.dropWhileEnd (== 255) start) of
      Nothing -> "\0"
      Just (rest, lastByte) -> BS.snoc rest (lastByte + 1)

rangeRequest :: Maybe Revision -> Range -> P.RangeRequest
rangeRequest revision range =
  defMessage
    & #key .~ start
    & #rangeEnd .~ end
    & #revision .~ maybe 0 revisionNumber revision
  where
    (start, end) = bounds range

compareRequest :: Compare -> P.Compare
compareRequest (Missing key) =
  defMessage
    & #key .~ T.encodeUtf8 key
    & #target .~ P.Compare'VERSION
    & #version .~ 0
compareRequest (Modified key revision) =
  defMessage
    & #key .~ T.encodeUtf8 key
    & #target .~ P.Compare'MOD
    & #modRevision .~ revisionNumber revision

changeRequest :: Change -> P.RequestOp
changeRequest (Put key value lease) =
  defMessage & #requestPut .~ put
  where
    put =
      defMessage
        & #key .~ T.encodeUtf8 key
        & #value .~ value
        & #lease .~ maybe 0 leaseNumber lease
changeRequest (Delete key) =
  defMessage & #requestDeleteRange .~ (defMessage & #key .~ T.encodeUtf8 key)

txn :: Client -> [P.Compare] -> [P.RequestOp] -> IO (Revision, P.TxnResponse)
txn client comparisons requests = do
  let request = defMessage & #compare .~ comparisons & #success .~ requests
      method = Proxy @(Protobuf P.KV "txn")
  response <- getProto <$> unaryWith transactionSeconds client method (Proto request)
  checkCluster client (response ^. #maybe'header)
  let expected = if response ^. #succeeded then length requests else 0
  rev <- toRevision (response ^. #header . #revision)
  unless (length (response ^. #responses) == expected) $
    fail "Incomplete etcd transaction response"
  pure (rev, response)

-- A failed comparison has no write revision.
transaction :: Client -> [Compare] -> [Change] -> IO (Maybe Revision)
transaction client comparisons changes = do
  (rev, response) <- txn client (map compareRequest comparisons) (map changeRequest changes)
  pure $ if response ^. #succeeded then Just rev else Nothing

-- | Each request contributes one range and consumes its own reply. Applicative
-- composition keeps the result shape when requests cross transaction batches.
data Reads a = Reads (Endo [Range]) (StateT [[Entry]] Maybe a) deriving (Functor)

instance Applicative Reads where
  pure = Reads mempty . pure
  Reads left f <*> Reads right x = Reads (left <> right) (f <*> x)

requestRange :: Range -> Reads [Entry]
requestRange range = Reads (Endo (range :)) (StateT uncons)

point :: Text -> Reads (Maybe Entry)
point key = listToMaybe <$> requestRange (Key key)

prefix :: Text -> Reads [Entry]
prefix = requestRange . Prefix

-- | Read every batch at the MVCC revision of the first transaction.
readSnapshot :: Client -> Reads a -> IO (Revision, a)
readSnapshot client (Reads requests consume) = do
  (revision, replies) <- readBatch Nothing (appEndo requests [])
  case runStateT consume replies of
    Just (value, []) -> pure (revision, value)
    _ -> fail "Wrong number of etcd snapshot replies"
  where
    readBatch pinned rest = do
      let (batch, remaining) = splitAt 128 rest
          readOp range = defMessage & #requestRange .~ rangeRequest pinned range
      (current, response) <- txn client [] (map readOp batch)
      let revision = fromMaybe current pinned
          rangeOf op =
            maybe (fail "Expected an etcd range response") pure (op ^. #maybe'responseRange)
      unless (response ^. #succeeded && current >= revision) $
        fail "Incomplete etcd snapshot"
      ranges <- mapM rangeOf (response ^. #responses)
      entries <- zipWithM (decodeRange revision) batch ranges
      if null remaining
        then pure (revision, entries)
        else do
          (_, later) <- readBatch (Just revision) remaining
          pure (revision, entries ++ later)

-- Standalone reads use the unary Range RPC and its shorter command deadline.
readPoint :: Client -> Text -> IO (Maybe Entry)
readPoint client key = listToMaybe . snd <$> readRange client (Key key)

readPrefix :: Client -> Text -> IO (Revision, [Entry])
readPrefix client = readRange client . Prefix

readRange :: Client -> Range -> IO (Revision, [Entry])
readRange client wanted = do
  let method = Proxy @(Protobuf P.KV "range")
  response <- getProto <$> unary client method (Proto (rangeRequest Nothing wanted))
  checkCluster client (response ^. #maybe'header)
  revision <- toRevision (response ^. #header . #revision)
  entries <- decodeRange revision wanted response
  pure (revision, entries)

decodeRange :: Revision -> Range -> P.RangeResponse -> IO [Entry]
decodeRange revision wanted range = do
  let entries = range ^. #kvs
  when (range ^. #more || range ^. #count /= fromIntegral (length entries)) $
    fail "Incomplete etcd range"
  case (wanted, entries) of
    (Key _, _ : _ : _) -> fail "Multiple entries for one etcd key"
    _ -> pure ()
  catMaybes <$> mapM entryOf entries
  where
    inRange raw = case wanted of
      Key k -> raw == T.encodeUtf8 k
      Prefix p -> T.encodeUtf8 p `BS.isPrefixOf` raw
    entryOf kv = do
      let raw = kv ^. #key
      modified <- toRevision (kv ^. #modRevision)
      unless (inRange raw && modified <= revision) $ fail "Unexpected etcd snapshot entry"
      let entry key = Entry key (kv ^. #value) modified (leaseFromWire (kv ^. #lease))
      pure (entry <$> decodeKey raw)

-- etcd permits arbitrary bytes in keys. Once range membership is checked,
-- a key outside UTF-8 cannot refer to any mesh record.
decodeKey :: ByteString -> Maybe Text
decodeKey = either (const Nothing) Just . T.decodeUtf8'

data Lease = Lease {leaseId :: LeaseId, leaseTTL :: Int64, expiresAt :: Integer}

monotonicMicros :: IO Integer
monotonicMicros = (`div` 1000) . toInteger <$> getMonotonicTimeNSec

-- Count from the request, so time spent in flight cannot extend a lease.
leaseAt :: Integer -> LeaseId -> Int64 -> Lease
leaseAt sent ident ttl = Lease ident ttl (sent + toInteger ttl * 1000000)

grant :: Client -> Int64 -> IO Lease
grant client seconds = do
  when (seconds <= 0) $ fail "Invalid etcd lease TTL"
  sent <- monotonicMicros
  let method = Proxy @(Protobuf P.Lease "leaseGrant")
  response <- unary client method (defMessage & #ttl .~ seconds)
  checkCluster client (getProto response ^. #maybe'header)
  let ttl = response ^. #ttl
  unless (T.null (response ^. #error) && ttl > 0) $
    fail "etcd did not grant the requested lease"
  lease <- maybe (fail "etcd returned an empty lease ID") pure (leaseFromWire (response ^. #id))
  pure (leaseAt sent lease ttl)

revoke :: Client -> Lease -> IO ()
revoke client = revokeLease client . leaseId

revokeLease :: Client -> LeaseId -> IO ()
revokeLease client lease = do
  let method = Proxy @(Protobuf P.Lease "leaseRevoke")
  response <- unary client method (defMessage & #id .~ leaseNumber lease)
  checkCluster client (getProto response ^. #maybe'header)

data LeaseFailure = LeaseExpired | UnexpectedLeaseId deriving (Show)

instance Exception LeaseFailure where
  displayException LeaseExpired = "Mesh instance lease expired"
  displayException UnexpectedLeaseId = "Unexpected etcd keepalive lease ID"

-- | Each stream authenticates afresh. The callback spans reconnects and runs
-- once, after etcd confirms the registration's own lease.
keepAlive :: Client -> Lease -> (Int64 -> IO ()) -> IO a
keepAlive client initial confirmed = do
  acks <- newEmptyMVar
  let ident = leaseId initial
      method = Proxy @(Protobuf P.Lease "leaseKeepAlive")
      renew call previousTTL = do
        sent <- monotonicMicros
        -- A coalescing proxy may wait a full third of the TTL for its
        -- upstream renewal. Allow half the TTL and keep time for reconnect.
        response <- deadlineMicros (ttlFraction previousTTL 2) $ do
          G.sendNextInput call (defMessage & #id .~ leaseNumber ident)
          G.recvNextOutput call
        checkCluster client (getProto response ^. #maybe'header)
        let ttl = response ^. #ttl
        unless (response ^. #id == leaseNumber ident) $ throwIO UnexpectedLeaseId
        when (ttl <= 0) $ throwIO LeaseExpired
        putMVar acks (leaseAt sent ident ttl)
        threadDelay (ttlFraction (min ttl 60) 3)
        renew call ttl
      session = stream client method $ \_ call -> renew call (leaseTTL initial)
      sessions = forever $ catchJust retryLeaseStream session (const $ threadDelay 250000)
      -- Only a matching positive reply advances the deadline. Waiting here
      -- also bounds blocked authentication, stream startup and retries.
      await previous = do
        now <- monotonicMicros
        let remaining = expiresAt previous - now
        when (remaining <= 0) $ throwIO LeaseExpired
        next <- timeout (fromInteger (min remaining 60000000)) (takeMVar acks)
        maybe (await previous) pure next
      maintain previous = await previous >>= maintain
      whileConfirmed = do
        first <- await initial
        fst <$> concurrently (maintain first) (confirmed (leaseTTL first))
  snd <$> concurrently sessions whileConfirmed

-- A fraction of a TTL in microseconds.
ttlFraction :: Int64 -> Integer -> Int
ttlFraction ttl divisor =
  fromInteger (min (toInteger (maxBound :: Int)) (toInteger ttl * 1000000 `div` divisor))

-- Watch ----------------------------------------------------------------------

type WatchRPC = Protobuf P.Watch "watch"

-- One authenticated watch stream and where it reports.
data Watcher = Watcher
  { -- The connection whose cluster every response must come from.
    owner :: Client,
    -- The connection for quorum probes, also handed to the event handler.
    prober :: Client,
    rpc :: G.Call WatchRPC,
    watched :: [Text],
    -- The first revision this stream may report.
    from :: Revision,
    -- The newest revision the caller has handled.
    handled :: IO Revision,
    -- A key every watched prefix covers for the heartbeat and quorum probe.
    probeKey :: ByteString,
    -- Set by every batch with a new event, taken by the idle probe.
    activity :: MVar (),
    handler :: [(Text, Revision)] -> IO ()
  }

-- A watch response is a control acknowledgment or a batch of changed keys.
type WatchMessage = Either WatchControl [(Text, Revision)]

-- | Start each authenticated stream after the last snapshot covering every prefix.
watch :: Client -> IO Revision -> [Text] -> (Client -> [(Text, Revision)] -> IO ()) -> IO a
watch _ _ [] _ = fail "An etcd watch requires a prefix"
watch client checkpoint prefixes@(first : _) onEvents = forever $
  stream client (Proxy @WatchRPC) $ \route call -> withWatchProbe route $ \prober -> do
    revision <- checkpoint >>= nextRevision
    activity <- newEmptyMVar
    let probeKey = fst (bounds (Prefix first))
        w = Watcher client prober call prefixes revision checkpoint probeKey activity (onEvents prober)
    -- A renewed stream restarts the idle probe's wait, so every stream also
    -- checks once at its start.
    probe w
    race_ (forever (probeWhenIdle w)) $ do
      installed <- subscribeAll w
      -- A heartbeat uses the original stream's immutable token. Renew an
      -- established stream; a rejection during initial subscription propagates.
      listen w installed `catch` \WatchTokenExpired -> deadline 6 (G.sendEndOfInput call)

-- Creates one watch per prefix and returns their distinct IDs.
subscribeAll :: Watcher -> IO (Set.Set Int64)
subscribeAll w = do
  let subscribe watchedPrefix =
        let (start, end) = bounds (Prefix watchedPrefix)
         in create w $
              defMessage
                & #key .~ start
                & #rangeEnd .~ end
                & #startRevision .~ revisionNumber (from w)
                & #progressNotify .~ True
      acknowledged = replicateM (length (watched w)) (expectCreated w 16 (receive w))
  (_, ids) <- concurrently (mapM_ subscribe (watched w)) acknowledged
  let installed = Set.fromList ids
  unless (Set.size installed == length ids) $ fail "Duplicate etcd watch ID"
  pure installed

-- Delivers each batch until the stream fails. A receive that stays silent for
-- ten seconds is checked with a heartbeat.
listen :: Watcher -> Set.Set Int64 -> IO a
listen w installed =
  forever $ withAsync (receive w) $ \reader -> do
    -- Waiting times out without canceling the outstanding receive.
    ready <- timeout 10000000 (wait reader)
    case ready of
      Nothing -> heartbeat w installed (wait reader)
      Just (Right events) -> deliver w events
      Just (Left _) -> fail "Unexpected etcd watch acknowledgment"

-- An authorized point watch that filters PUT and DELETE never replays or
-- publishes data. Its pair of acknowledgments tests the existing Watch
-- RPC even when the connection stalls or a server admits one stream.
heartbeat :: Watcher -> Set.Set Int64 -> IO WatchMessage -> IO ()
heartbeat w installed next = do
  let silent = [Proto P.WatchCreateRequest'NOPUT, Proto P.WatchCreateRequest'NODELETE]
  deadline 6 $ create w (defMessage & #key .~ probeKey w & #filters .~ silent)
  ident <- expectCreated w 6 next
  when (Set.member ident installed) $ fail "Duplicate etcd watch ID"
  deadline 6 $ G.sendNextInput (rpc w) (defMessage & #cancelRequest .~ cancel ident)
  reply <- control w 6 (receive w)
  unless (reply == Canceled ident) $ fail "Unexpected etcd watch acknowledgment"
  where
    cancel ident = defMessage & #watchId .~ ident

-- grpc-proxy does not forward explicit progress requests. An idle
-- watcher must also confirm that its upstream can still reach quorum.
probeWhenIdle :: Watcher -> IO ()
probeWhenIdle w = do
  threadDelay 10000000
  heard <- tryTakeMVar (activity w)
  when (isNothing heard) (probe w)

-- Confirms the upstream reaches quorum and has not gone back. A cluster
-- restored to an older revision leaves the watch waiting for, or the caller
-- ignoring, revisions it already handled, so the watcher starts over.
probe :: Watcher -> IO ()
probe w = do
  -- Read before the request: an event handled meanwhile must not count as
  -- newer than the answer.
  latest <- handled w
  let request = defMessage & #key .~ probeKey w & #countOnly .~ True
  response <- unary (prober w) (Proxy @(Protobuf P.KV "range")) request
  let header = getProto response ^. #maybe'header
  checkCluster (prober w) header
  case header of
    Just h | h ^. #revision < revisionNumber latest -> fail "etcd revision went back behind the watch"
    _ -> pure ()

create :: Watcher -> Proto P.WatchCreateRequest -> IO ()
create w request = G.sendNextInput (rpc w) (defMessage & #createRequest .~ request)

receive :: Watcher -> IO WatchMessage
receive w = do
  response <- G.recvNextOutput (rpc w)
  checkWatchCluster (owner w) response
  watchMessage (from w) (watched w) response

-- Only events newer than what the caller handled show the watch is current;
-- after a restore, older ones keep arriving while the caller ignores them.
deliver :: Watcher -> [(Text, Revision)] -> IO ()
deliver w events = unless (null events) $ do
  latest <- handled w
  when (any ((> latest) . snd) events) . void $ tryPutMVar (activity w) ()
  handler w events

-- Waits for the next acknowledgment and delivers the events before it.
-- Applying a replayed event can take longer than a control round trip, so
-- each receive has its own deadline and the handler runs outside it.
control :: Watcher -> Int -> IO WatchMessage -> IO WatchControl
control w seconds next = do
  message <- deadline seconds next
  case message of
    Left reply -> pure reply
    Right events -> deliver w events >> control w seconds (receive w)

expectCreated :: Watcher -> Int -> IO WatchMessage -> IO Int64
expectCreated w seconds next = do
  reply <- control w seconds next
  case reply of
    Created ident -> pure ident
    Canceled _ -> fail "Unexpected etcd watch cancellation"

data WatchControl = Created Int64 | Canceled Int64 deriving (Eq)

data WatchTokenExpired = WatchTokenExpired deriving (Show)

instance Exception WatchTokenExpired

checkWatchCluster :: Client -> Proto P.WatchResponse -> IO ()
checkWatchCluster client response =
  case getProto response ^. #maybe'header of
    -- grpc-proxy can acknowledge a coalesced create with only a revision,
    -- or a local cancel with an empty last header. It forwards upstream
    -- cluster IDs on events and progress notifications.
    Just header
      | response ^. #created || response ^. #canceled,
        null (response ^. #events),
        response ^. #compactRevision == 0,
        not (response ^. #fragment),
        header == (defMessage & #revision .~ header ^. #revision) ->
          pure ()
    header -> checkCluster client header

watchMessage :: Revision -> [Text] -> Proto P.WatchResponse -> IO WatchMessage
watchMessage firstRevision prefixes response
  | response ^. #compactRevision == 0,
    response ^. #created,
    response ^. #canceled,
    null events,
    expiredWatchReason reason =
      throwIO WatchTokenExpired
  | response ^. #compactRevision /= 0 || not (T.null reason) =
      fail ("etcd watch canceled: " ++ T.unpack reason)
  | otherwise = case (response ^. #created, response ^. #canceled) of
      (False, False) -> Right . catMaybes <$> traverse decode events
      (True, False) -> acknowledgment Created
      (False, True) -> acknowledgment Canceled
      (True, True) -> fail "Etcd rejected watch creation"
  where
    reason = response ^. #cancelReason
    events = response ^. #events
    acknowledgment make
      | null events, ident >= 0 = pure (Left (make ident))
      | otherwise = fail "Invalid etcd watch acknowledgment"
      where
        ident = response ^. #watchId
    decode event = do
      let kv = event ^. #kv
      revision <- toRevision (kv ^. #modRevision)
      let raw = kv ^. #key
          watched' = any ((`BS.isPrefixOf` raw) . T.encodeUtf8) prefixes
      unless (revision >= firstRevision && watched') $ fail "Unexpected etcd watch event"
      pure ((,revision) <$> decodeKey raw)
