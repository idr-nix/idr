module IDR.Mesh.Etcd.Config (Server (..)) where

-- | Endpoint URL, etcd user and the file holding its password.
data Server = Server String String FilePath
