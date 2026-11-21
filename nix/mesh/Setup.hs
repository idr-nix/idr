module Main (main) where

import Distribution.Simple
import Distribution.Simple.BuildPaths (autogenPackageModulesDir)
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo, buildDir, withPrograms)
import Distribution.Simple.Program (Program, programFindVersion, requireProgramVersion, runProgram, simpleProgram)
import Distribution.Simple.Utils (findProgramVersion, getDirectoryContentsRecursive, installOrdinaryFiles, withTempDirectory)
import Distribution.Verbosity (normal)
import Distribution.Version (mkVersion, withinVersion)
import System.FilePath (takeExtension, (</>))

main :: IO ()
main =
  defaultMainWithHooks
    simpleUserHooks
      { hookedPrograms = [agda],
        buildHook = \pkg info hooks flags -> generate info >> buildHook simpleUserHooks pkg info hooks flags,
        replHook = \pkg info hooks flags targets -> generate info >> replHook simpleUserHooks pkg info hooks flags targets
      }

agda :: Program
agda = (simpleProgram "agda") {programFindVersion = findProgramVersion "--numeric-version" id}

generate :: LocalBuildInfo -> IO ()
generate info = withTempDirectory normal (buildDir info) "mesh-agda" $ \source -> do
  (compiler, _, _) <- requireProgramVersion normal agda (withinVersion (mkVersion [2, 8])) (withPrograms info)
  let directory = autogenPackageModulesDir info
  -- Typecheck the sources afresh without writing .agdai beside the checked-in files.
  files <- getDirectoryContentsRecursive "src"
  installOrdinaryFiles normal source [("src", f) | f <- files, takeExtension f == ".agda"]
  runProgram
    normal
    compiler
    [ "--no-libraries",
      "--compile",
      "--ghc-dont-call-ghc",
      "--no-main",
      "-i" ++ source,
      "--compile-dir=" ++ directory,
      source </> "IDR/Mesh/Foreign.agda"
    ]
