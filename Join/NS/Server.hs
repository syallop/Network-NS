{-# LANGUAGE OverloadedStrings #-}
module Join.NS.Server
  (runNewServer
  ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.Async (race)
import           Control.Monad
import           Data.ByteString                        hiding (foldr)
import qualified Data.Map                        as Map
import           Data.Maybe
import           Data.Serialize
import           Data.Unique
import           Network
import           System.IO                              hiding (hPutStr)

import Prelude hiding (null)

import Join.NS.Types


-- | Map clientId's to the list of ChannelNames they own
-- and vice-versa.
newtype ChannelNamesMap = ChannelNamesMap
  {unChannelNamesMap :: (Map.Map ChannelName ClientId
                        ,Map.Map ClientId    [ChannelName]
                        )
  }

emptyChannelNamesMap :: ChannelNamesMap
emptyChannelNamesMap = ChannelNamesMap (Map.empty,Map.empty)

-- | Map a ClientId <-> [ChannelName] overwriting any previous associations
insert :: ClientId -> [ChannelName] -> ChannelNamesMap -> ChannelNamesMap
insert cId cNames (ChannelNamesMap (nameToId,idToNames)) =
  let newNameToId = Map.fromList [(cName,cId) | cName <- cNames]
      nameToId'   = newNameToId `Map.union` nameToId
      idToNames'  = Map.insertWith (++) cId cNames idToNames
     in ChannelNamesMap (nameToId',idToNames')

-- | Lookup the ClientId who has registered the given ChannelName.
lookupClientId :: ChannelName -> ChannelNamesMap -> Maybe ClientId
lookupClientId cName (ChannelNamesMap (nameToId,_)) = Map.lookup cName nameToId

-- | Lookup all ChannelNames registered by the given ClientId.
lookupNames :: ClientId -> ChannelNamesMap -> Maybe [ChannelName]
lookupNames cId (ChannelNamesMap (_,idToNames)) = Map.lookup cId idToNames

-- | Remove a ClientId and all of their registered ChannelNames from the map.
-- Unaltered when clientId does not exist.
removeClient :: ClientId -> ChannelNamesMap -> ChannelNamesMap
removeClient cId m@(ChannelNamesMap (nameToId,idToNames)) = case lookupNames cId m of
  Nothing -> m -- Client not in map
  Just ns
    -> let nameToId'  = foldr (\name nameToId' -> Map.delete name nameToId') nameToId ns
           idToNames' = Map.delete cId idToNames
          in ChannelNamesMap (nameToId',idToNames')


-- | Store data related to a connected client.
data ClientConn = ClientConn
  {_clientId     :: ClientId       -- ^ Globally unique clientId
  ,_clientHandle :: Handle         -- ^ Communication handle
  ,_clientMsgIn  :: Chan ClientMsg -- ^ Queue of incomming messages
  ,_clientMsgOut :: Chan ServerMsg -- ^ Queue of outgoing messages
  }

-- | State of a running nameserver.
data Server = Server
  { -- | All connected clients, indexed by their id
    _clientConns  :: MVar (Map.Map ClientId ClientConn)

   -- | Map clientIds <-> channelNames
  , _channelNames :: MVar ChannelNamesMap
  }

newServer :: IO Server
newServer = Server <$> newMVar Map.empty
                   <*> newMVar emptyChannelNamesMap

-- | Add a new client to the server, returning the ClientConn.
addClientConn :: ClientId -> Handle -> Server -> IO ClientConn
addClientConn cId cHandle server = do
  cs <- takeMVar (_clientConns server)
  c  <- ClientConn <$> pure cId
                   <*> pure cHandle
                   <*> newChan
                   <*> newChan
  putMVar (_clientConns server) (Map.insert cId c cs)
  return c

-- | Lookup the ClientConn associated with an Id.
lookupClientConn :: ClientId -> Server -> IO (Maybe ClientConn)
lookupClientConn cId s = do
  cs <- readMVar (_clientConns s)
  return $ Map.lookup cId cs

-- | Queue a ServerMsg to be sent to the client.
sendToClient :: ClientConn -> ServerMsg -> IO ()
sendToClient c smsg = writeChan (_clientMsgOut c) smsg

-- | Queue a ClientMsg read from the client.
receivedFromClient :: ClientConn -> ClientMsg -> IO ()
receivedFromClient c cmsg = writeChan (_clientMsgIn c) cmsg

-- | Queue a ServerMsg to be sent to all clients.
broadcastToClients :: Server -> ServerMsg -> IO ()
broadcastToClients s smsg = do
  cs <- takeMVar (_clientConns s)
  mapM_ (`sendToClient` smsg) (Map.elems cs)
  putMVar (_clientConns s) cs

-- | Run a new instance of a nameserver.
runNewServer :: Int -> IO ()
runNewServer port
  | port < 0 = error "Int port number must be > 0"
  | otherwise = withSocketsDo $ do
      server <- newServer
      socket <- listenOn $ PortNumber $ fromIntegral port
      forever $ do
        (cHandle, cHost, cPort) <- accept socket
        forkFinally (newClient cHandle server) (\_ -> hClose cHandle)

-- | Handle a newly connected client by registering them
-- the server and dealing with all incoming and outgoing messages.
newClient :: Handle -> Server -> IO ()
newClient cHandle server = do

  hSetBuffering cHandle NoBuffering
  cId        <- hashUnique <$> newUnique
  clientConn <- addClientConn cId cHandle server

  serveClient clientConn server

-- | Concurrently and continually:
-- - Parse incoming messages into ClientMsg's
-- - Handle the queue of valid incoming ClientMsg
-- - Handle the queue of valid outgoing ServerMsg
--
-- Terminating all threads when any returns which will happen if:
-- - A ClientQuit message is received
-- - A ServerQuit message is sent
-- - The client handle dies
-- - A misc exception is thrown
serveClient :: ClientConn -> Server -> IO ()
serveClient c s = void $ race (readInput "") $ race handleMsgInQueue handleMsgOutQueue
  where
    -- Continually read, parse and queue incoming messages.
    readInput :: ByteString -> IO ()
    readInput leftover = do
      msgPart <- hGetSome (_clientHandle c) 1024
      if null msgPart
        then return () -- EOF, Client unexpectedly died.
        else let result = runGetPartial (get :: Get ClientMsg) (leftover `append` msgPart)
                in caseParseResult result

    -- Handle the result of an attempt to parse some input
    caseParseResult :: Result ClientMsg -> IO ()
    caseParseResult result = case result of

        -- Parser failed. Continue with leftovers.
        Fail e leftover'
          -> readInput leftover'

        -- Complete ClientMsg read. Queue and continue with any leftovers.
        Done msg leftover'
          -> do receivedFromClient c msg
                readInput leftover'

        -- More input required. Attempt to read more and try again.
        Partial f
          -> do msgPart <- hGetSome (_clientHandle c) 1024
                if null msgPart
                  then return ()
                  else caseParseResult (f msgPart)

      -- Handle the messages in the input queue until continue=False
    handleMsgInQueue :: IO ()
    handleMsgInQueue = join $ do
      inMsg <- readChan (_clientMsgIn c)
      return $ do
        continue <- handleMsgIn inMsg c s
        when continue handleMsgInQueue

    -- Handle the messages in the output queue until continue=False
    handleMsgOutQueue :: IO ()
    handleMsgOutQueue = join $ do
      outMsg <- readChan (_clientMsgOut c)
      return $ do
        continue <- handleMsgOut outMsg c s
        when continue handleMsgOutQueue

-- | Handle a single message from a clients input queue,
-- returning a bool indicating whether the connection should be closed.
handleMsgIn :: ClientMsg -> ClientConn -> Server -> IO Bool
handleMsgIn cmsg c s = case cmsg of

  -- Client is quitting. Notify other clients
  -- of any unregistered channelnames and stop communication.
    ClientQuit
      -> do nm <- takeMVar (_channelNames s)

            -- Remove client from server
            cs <- takeMVar (_clientConns s)
            let cs' = Map.delete (_clientId c) cs
            putMVar (_clientConns s) cs'

            case lookupNames (_clientId c) nm of

                -- Should be unreachable
                Nothing -> error "Client not registered in server state"

                -- Client hasnt registered any channelnames
                Just []
                  -> putMVar (_channelNames s) nm

                -- Client registered >= 1 channelname
                Just (n:ns)
                  -> do let nm' = removeClient (_clientId c) nm
                        putMVar (_channelNames s) nm'

                        broadcastToClients s (Unregistered n ns)
            return False

    -- Client requests registration of a ChannelName
    Register cName
      -> do ns <- takeMVar (_channelNames s)
            case lookupClientId cName ns of

              -- name already taken
                Just _
                  -> do putMVar (_channelNames s) ns
                        sendToClient c (RegisterResp cName False)

                -- name free => registered to client
                Nothing
                  -> do putMVar (_channelNames s) (insert (_clientId c) [cName] ns)
                        sendToClient c (RegisterResp cName True)
            return True

    -- Client queries the existance of a channelName
    Query cName
      -> do ns <- readMVar (_channelNames s)
            case lookupClientId cName ns of

                -- ChannelName doesnt exist
                Nothing -> sendToClient c (QueryResp cName False)

                -- ChannelName exists
                Just _  -> sendToClient c (QueryResp cName True)
            return True

    -- Client requests that the Msg is sent to the owner of ChannelName
    MsgTo cName msg
      -> do ns <- readMVar (_channelNames s)
            case lookupClientId cName ns of

                -- ChannelName isnt registered. Silently drop message.
                Nothing
                  -> return True

                Just targetCId
                  -> do targetClient <- fromJust <$> lookupClientConn targetCId s
                        sendToClient targetClient (MsgFor cName msg)
                        return True

-- | Encode and write outgoing messages to the client.
-- Determining that we should quit communication
-- if we're sending a ServerQuit.
handleMsgOut :: ServerMsg -> ClientConn -> Server -> IO Bool
handleMsgOut smsg c s = do
  hPutStr (_clientHandle c) (encode smsg)
  return $ case smsg of
      ServerQuit -> False
      _          -> True

