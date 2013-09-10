
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Foreign.C.Types
import Network hiding (accept, socketPort, recvFrom, sendTo)
import Network.BSD
import Network.Socket
import Control.Applicative
import Control.Exception
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Network.Wai
import qualified Network.Wai.Handler.Warp as Warp
import Network.HTTP.Types
import Blaze.ByteString.Builder.Char.Utf8
import System.Posix
import System.Prefork
import System.Environment

data Config = Config Warp.Settings

data Worker = Worker {
    wSocketFd :: CInt
  } deriving (Show, Read)

instance WorkerContext Worker

data Server = Server {
    sProcs     :: TVar ([ProcessID])
  , sServerSoc :: TVar (Maybe Socket)
  }

main :: IO ()
main = do
  s <- Server <$> newTVarIO [] <*> newTVarIO Nothing
  let settings = defaultSettings {
      psUpdateConfig = updateConfig
    , psUpdateServer = updateServer s
    , psCleanupChild = cleanupChild s
    }
  compatMain settings $ \w@(Worker fd) -> do
    soc <- mkSocket fd AF_INET Stream defaultProtocol Listening
    sockAddr <- getSocketName soc
    case sockAddr of
      SockAddrInet port addr -> do
        Warp.runSettingsSocket Warp.defaultSettings { Warp.settingsPort = fromIntegral port } soc $ serverApp
        return ()
      _ -> return ()
    return ()
  where
    serverApp :: Application
    serverApp _ = return $ ResponseBuilder status200 [] $ fromString "hello"

updateConfig :: IO (Maybe Config)
updateConfig = do
  let settings = Warp.defaultSettings
  return (Just $ Config settings)

updateServer :: Server -> Config -> IO ([ProcessID])
updateServer server@Server { sServerSoc = socVar } config = do
  msoc <- readTVarIO socVar
  soc <- case msoc of
    Just soc -> return (soc)
    Nothing -> do
      hentry <- getHostByName "localhost"
      soc <- listenOnAddr (SockAddrInet 11111 (head $ hostAddresses hentry))
      atomically $ writeTVar socVar (Just soc)
      return (soc)
  pids <- forM [1..10] $ \_ -> forkWorkerProcess (Worker (fdSocket soc))
  return (pids)

cleanupChild :: Server -> Config -> ProcessID -> IO ()
cleanupChild server config pid = do
  return ()

listenOnAddr :: SockAddr -> IO Socket
listenOnAddr sockAddr = do
  let backlog = 1024
  proto <- getProtocolNumber "tcp"
  bracketOnError
    (socket AF_INET Stream proto)
    (sClose)
    (\sock -> do
      setSocketOption sock ReuseAddr 1
      bindSocket sock sockAddr
      listen sock backlog
      return sock
    )