module IDR.Mesh.Duration (Seconds, parseSeconds, secondsValue, milliseconds) where

import Data.Int (Int64)
import Text.Read (readMaybe)

newtype Seconds = Seconds Int64

parseSeconds :: Int64 -> Int64 -> String -> Either String Seconds
parseSeconds least most value = case readMaybe value :: Maybe Integer of
  Just n | n >= toInteger least && n <= toInteger most -> Right (Seconds (fromInteger n))
  _ -> Left ("Expected a duration between " ++ show least ++ " and " ++ show most ++ " seconds")

secondsValue :: Seconds -> Int64
secondsValue (Seconds n) = n

milliseconds :: Seconds -> Integer
milliseconds seconds = toInteger (secondsValue seconds) * 1000
