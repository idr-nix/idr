{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- The agent's view of etcd. `withEtcd` opens one authenticated connection and
-- every operation inside it uses that connection, so no code passes a client
-- around. `keepAlive` and `watch` take effect actions; the threads they need
-- stay inside this module.
module IDR.Mesh.Etcd.Effect
  ( Etcd,
    withEtcd,
    sameCluster,
    clusterId,
    readSnapshot,
    transaction,
    grant,
    revoke,
    revokeLease,
    keepAlive,
    watch,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Static
import IDR.Mesh.Etcd qualified as E

data Etcd :: Effect

type instance DispatchOf Etcd = Static WithSideEffects

newtype instance StaticRep Etcd = Etcd E.Client

-- Runs the action on the connection the connector opens, for example
-- `E.withMeshEtcd server`.
withEtcd ::
  (IOE :> es) =>
  (forall r. (E.Client -> IO r) -> IO r) ->
  Eff (Etcd : es) a ->
  Eff es a
withEtcd connect action =
  withEffToIO concurrently $ \unlift -> connect (\c -> unlift (evalStaticRep (Etcd c) action))

-- A new connection to the cluster of the current one.
sameCluster :: (Etcd :> es, IOE :> es) => Eff (Etcd : es) a -> Eff es a
sameCluster action = do
  current <- client
  withEtcd (E.withSameCluster current) action

clusterId :: (Etcd :> es) => Eff es E.ClusterId
clusterId = E.clusterId <$> client

readSnapshot :: (Etcd :> es) => E.Reads a -> Eff es (E.Revision, a)
readSnapshot query = client >>= \c -> unsafeEff_ (E.readSnapshot c query)

-- A failed comparison has no write revision.
transaction :: (Etcd :> es) => [E.Compare] -> [E.Change] -> Eff es (Maybe E.Revision)
transaction compares changes = client >>= \c -> unsafeEff_ (E.transaction c compares changes)

grant :: (Etcd :> es) => Int64 -> Eff es E.Lease
grant ttl = client >>= \c -> unsafeEff_ (E.grant c ttl)

revoke :: (Etcd :> es) => E.Lease -> Eff es ()
revoke lease = client >>= \c -> unsafeEff_ (E.revoke c lease)

revokeLease :: (Etcd :> es) => E.LeaseId -> Eff es ()
revokeLease lease = client >>= \c -> unsafeEff_ (E.revokeLease c lease)

-- Runs the action once the lease is confirmed and renews the lease until it is
-- lost, which ends the scope with an exception.
keepAlive :: (Etcd :> es, IOE :> es) => E.Lease -> Eff es () -> Eff es a
keepAlive lease action = do
  c <- client
  withEffToIO concurrently $ \unlift -> E.keepAlive c lease (\_ -> void (unlift action))

-- Calls the handler with each batch of changed keys, after the checkpoint
-- revision, on the connection the watch currently uses.
watch ::
  (Etcd :> es, IOE :> es) =>
  Eff es E.Revision ->
  [Text] ->
  ([(Text, E.Revision)] -> Eff es ()) ->
  Eff es a
watch checkpoint prefixes handle = do
  c <- client
  withEffToIO concurrently $ \unlift ->
    E.watch c (unlift checkpoint) prefixes $ \current events ->
      unlift (localStaticRep (const (Etcd current)) (handle events))

client :: (Etcd :> es) => Eff es E.Client
client = (\(Etcd c) -> c) <$> getStaticRep

-- The etcd client renews leases and watches on threads of its own.
concurrently :: UnliftStrategy
concurrently = ConcUnlift Persistent Unlimited
