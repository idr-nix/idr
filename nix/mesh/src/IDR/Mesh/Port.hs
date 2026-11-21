module IDR.Mesh.Port (parsePort) where

import Text.Read (readMaybe)

parsePort :: String -> Either String Int
parsePort value = case readMaybe value :: Maybe Integer of
  Just n | n >= 1 && n <= 65535 -> Right (fromInteger n)
  _ -> Left "Mesh port must be between 1 and 65535"
