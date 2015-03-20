{-# LANGUAGE ScopedTypeVariables #-}

-- TODO This module was originally based on the PackageTests.PackageTester
-- module in Cabal, however it has a few differences. I suspect that as
-- this module ages the two modules will diverge further. As such, I have
-- not attempted to merge them into a single module nor to extract a common
-- module from them.  Refactor this module and/or Cabal's
-- PackageTests.PackageTester to remove commonality.
--   2014-05-15 Ben Armston

-- | Routines for black-box testing cabal-install.
--
-- Instead of driving the tests by making library calls into
-- Distribution.Simple.* or Distribution.Client.* this module only every
-- executes the `cabal-install` binary.
--
-- You can set the following VERBOSE environment variable to control
-- the verbosity of the output generated by this module.
module PackageTests.PackageTester
    ( TestsPaths(..)
    , Result(..)

    , packageTestsDirectory
    , packageTestsConfigFile

    -- * Running cabal commands
    , cabal_clean
    , cabal_exec
    , cabal_freeze
    , cabal_install
    , cabal_sandbox
    , run

    -- * Test helpers
    , assertCleanSucceeded
    , assertExecFailed
    , assertExecSucceeded
    , assertFreezeSucceeded
    , assertInstallSucceeded
    , assertSandboxSucceeded
    ) where

import qualified Control.Exception.Extensible as E
import Control.Monad (when, unless)
import Data.Maybe (fromMaybe)
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getEnv)
import System.Exit (ExitCode(ExitSuccess))
import System.FilePath ( (<.>)  )
import System.IO (hClose, hGetChar, hIsEOF)
import System.IO.Error (isDoesNotExistError)
import System.Process (runProcess, waitForProcess)
import Test.Tasty.HUnit (Assertion, assertFailure)

import Distribution.Simple.BuildPaths (exeExtension)
import Distribution.Simple.Utils (printRawCommandAndArgs)
import Distribution.Compat.CreatePipe (createPipe)
import Distribution.ReadE (readEOrFail)
import Distribution.Verbosity (Verbosity, flagToVerbosity, normal)

data Success = Failure
             -- | ConfigureSuccess
             -- | BuildSuccess
             -- | TestSuccess
             -- | BenchSuccess
             | CleanSuccess
             | ExecSuccess
             | FreezeSuccess
             | InstallSuccess
             | SandboxSuccess
             deriving (Eq, Show)

data TestsPaths = TestsPaths
    { cabalPath  :: FilePath -- ^ absolute path to cabal executable.
    , ghcPkgPath :: FilePath -- ^ absolute path to ghc-pkg executable.
    , configPath :: FilePath -- ^ absolute path of the default config file
                             --   to use for tests (tests are free to use
                             --   a different one).
    }

data Result = Result
    { successful :: Bool
    , success    :: Success
    , outputText :: String
    } deriving Show

nullResult :: Result
nullResult = Result True Failure ""

------------------------------------------------------------------------
-- * Config

packageTestsDirectory :: FilePath
packageTestsDirectory = "PackageTests"

packageTestsConfigFile :: FilePath
packageTestsConfigFile = "cabal-config"

------------------------------------------------------------------------
-- * Running cabal commands

recordRun :: (String, ExitCode, String) -> Success -> Result -> Result
recordRun (cmd, exitCode, exeOutput) thisSucc res =
    res { successful = successful res && exitCode == ExitSuccess
        , success    = if exitCode == ExitSuccess then thisSucc
                       else success res
        , outputText =
            (if null $ outputText res then "" else outputText res ++ "\n") ++
            cmd ++ "\n" ++ exeOutput
        }

-- | Run the clean command and return its result.
cabal_clean :: TestsPaths -> FilePath -> [String] -> IO Result
cabal_clean paths dir args = do
    res <- cabal paths dir (["clean"] ++ args)
    return $ recordRun res CleanSuccess nullResult

-- | Run the exec command and return its result.
cabal_exec :: TestsPaths -> FilePath -> [String] -> IO Result
cabal_exec paths dir args = do
    res <- cabal paths dir (["exec"] ++ args)
    return $ recordRun res ExecSuccess nullResult

-- | Run the freeze command and return its result.
cabal_freeze :: TestsPaths -> FilePath -> [String] -> IO Result
cabal_freeze paths dir args = do
    res <- cabal paths dir (["freeze"] ++ args)
    return $ recordRun res FreezeSuccess nullResult

-- | Run the install command and return its result.
cabal_install :: TestsPaths -> FilePath -> [String] -> IO Result
cabal_install paths dir args = do
    res <- cabal paths dir (["install"] ++ args)
    return $ recordRun res InstallSuccess nullResult

-- | Run the sandbox command and return its result.
cabal_sandbox :: TestsPaths -> FilePath -> [String] -> IO Result
cabal_sandbox paths dir args = do
    res <- cabal paths dir (["sandbox"] ++ args)
    return $ recordRun res SandboxSuccess nullResult

-- | Returns the command that was issued, the return code, and the output text.
cabal :: TestsPaths -> FilePath -> [String] -> IO (String, ExitCode, String)
cabal paths dir cabalArgs = do
    run (Just dir) (cabalPath paths) args
  where
    args = configFileArg : cabalArgs
    configFileArg = "--config-file=" ++ configPath paths

-- | Returns the command that was issued, the return code, and the output text
run :: Maybe FilePath -> String -> [String] -> IO (String, ExitCode, String)
run cwd path args = do
    verbosity <- getVerbosity
    -- path is relative to the current directory; canonicalizePath makes it
    -- absolute, so that runProcess will find it even when changing directory.
    path' <- do pathExists <- doesFileExist path
                canonicalizePath (if pathExists then path else path <.> exeExtension)
    printRawCommandAndArgs verbosity path' args
    (readh, writeh) <- createPipe
    pid <- runProcess path' args cwd Nothing Nothing (Just writeh) (Just writeh)

    -- fork off a thread to start consuming the output
    out <- suckH [] readh
    hClose readh

    -- wait for the program to terminate
    exitcode <- waitForProcess pid
    let fullCmd = unwords (path' : args)
    return ("\"" ++ fullCmd ++ "\" in " ++ fromMaybe "" cwd, exitcode, out)
  where
    suckH output h = do
        eof <- hIsEOF h
        if eof
            then return (reverse output)
            else do
                c <- hGetChar h
                suckH (c:output) h

------------------------------------------------------------------------
-- * Test helpers

assertCleanSucceeded :: Result -> Assertion
assertCleanSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'cabal clean\' should succeed\n" ++
    "  output: " ++ outputText result

assertExecSucceeded :: Result -> Assertion
assertExecSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'cabal exec\' should succeed\n" ++
    "  output: " ++ outputText result

assertExecFailed :: Result -> Assertion
assertExecFailed result = when (successful result) $
    assertFailure $
    "expected: \'cabal exec\' should fail\n" ++
    "  output: " ++ outputText result

assertFreezeSucceeded :: Result -> Assertion
assertFreezeSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'cabal freeze\' should succeed\n" ++
    "  output: " ++ outputText result

assertInstallSucceeded :: Result -> Assertion
assertInstallSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'cabal install\' should succeed\n" ++
    "  output: " ++ outputText result

assertSandboxSucceeded :: Result -> Assertion
assertSandboxSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'cabal sandbox\' should succeed\n" ++
    "  output: " ++ outputText result

------------------------------------------------------------------------
-- Verbosity

lookupEnv :: String -> IO (Maybe String)
lookupEnv name =
    (fmap Just $ getEnv name)
    `E.catch` \ (e :: IOError) ->
        if isDoesNotExistError e
        then return Nothing
        else E.throw e

-- TODO: Convert to a "-v" flag instead.
getVerbosity :: IO Verbosity
getVerbosity = do
    maybe normal (readEOrFail flagToVerbosity) `fmap` lookupEnv "VERBOSE"
