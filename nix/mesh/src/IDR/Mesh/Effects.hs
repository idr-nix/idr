{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}

-- Effects shared by the agent and netd.
module IDR.Mesh.Effects
  ( Log,
    logLine,
    logFailure,
    runLog,
    Locks,
    exclusive,
    runLocks,
  )
where

import Control.Exception (SomeException)
import Effectful
import Effectful.Dispatch.Dynamic
import IDR.Mesh.Common qualified as Common

-- Diagnostics for the journal.
data Log :: Effect where
  LogLine :: String -> Log m ()

type instance DispatchOf Log = Dynamic

logLine :: (Log :> es) => String -> Eff es ()
logLine = send . LogLine

logFailure :: (Log :> es) => String -> SomeException -> Eff es ()
logFailure context err = logLine (context ++ ": " ++ Common.describe err)

runLog :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLog = interpret $ \_ -> \case
  LogLine message -> liftIO (Common.logLine message)

-- One lock per name, so work on one workload never overlaps.
data Locks :: Effect where
  Exclusive :: String -> m a -> Locks m a

type instance DispatchOf Locks = Dynamic

exclusive :: (Locks :> es) => String -> Eff es a -> Eff es a
exclusive name = send . Exclusive name

runLocks :: (IOE :> es) => Eff (Locks : es) a -> Eff es a
runLocks action = do
  locks <- liftIO Common.newLocks
  interpret (exclusively locks) action
  where
    exclusively :: (IOE :> es) => Common.Locks -> EffectHandler Locks es
    exclusively locks env = \case
      Exclusive name inner ->
        localUnliftIO env SeqUnlift $ \unlift ->
          Common.withNamedLock locks name (unlift inner)
