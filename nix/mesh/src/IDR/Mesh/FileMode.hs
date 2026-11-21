module IDR.Mesh.FileMode (setAccessMode) where

import Control.Exception (bracket)
import Control.Monad (unless, void, when)
import Foreign.C.Error
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Posix.Files (setFdMode)
import System.Posix.Types (CMode (..), Fd (..), FileMode)

data ACL

foreign import ccall safe "acl_get_fd" getAcl :: Fd -> IO (Ptr ACL)

foreign import ccall safe "acl_set_fd" setAcl :: Fd -> Ptr ACL -> IO CInt

foreign import ccall unsafe "acl_from_mode" aclFromMode :: FileMode -> IO (Ptr ACL)

foreign import ccall unsafe "acl_equiv_mode" equivalentMode :: Ptr ACL -> Ptr FileMode -> IO CInt

foreign import ccall unsafe "acl_free" freeAcl :: Ptr ACL -> IO CInt

-- Install the entire access ACL. chmod alone updates its mask and can grant
-- effective access to named entries inherited from the containing directory.
setAccessMode :: Maybe Fd -> Fd -> FileMode -> IO ()
setAccessMode source target mode = do
  bracket obtain (void . freeAcl) $ \acl -> do
    result <- setAcl target acl
    when (result < 0) $ do
      err <- getErrno
      plain <- equivalentMode acl nullPtr
      unless (err == eNOTSUP && plain == 0) $
        ioError (errnoToIOError "acl_set_fd" err Nothing Nothing)
  -- The ACL only represents rwx permissions, not the special mode bits.
  setFdMode target mode
  where
    plainAcl = throwErrnoIfNull "acl_from_mode" (aclFromMode mode)
    obtain = case source of
      Nothing -> plainAcl
      Just original -> do
        acl <- getAcl original
        if acl /= nullPtr
          then pure acl
          else do
            err <- getErrno
            if err == eNOTSUP
              then plainAcl
              else ioError (errnoToIOError "acl_get_fd" err Nothing Nothing)
