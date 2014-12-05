{-# LANGUAGE OverloadedStrings #-}
{-|
Module     : Join.NS.Server
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Defines a quick and dirty nameserver which acts as a central authority for
mapping 'ChannelName's to client's which have registered them.
The nameserver supports querying the existance of names as well as forwarding
ByteString 'encode'd messages.

A client for the nameserver is found at 'Join.NS.Client'.
-}
module Join.NS.Server
  (
  -- * Running nameserver
  -- | The nameserver may be ran by calling 'runNewServer PORT' to run an instance
  -- which listens for TCP connections on the given port.
  --
  -- Alternatively, cabal will build an executable named NS which accepts the port number
  -- as a commandline arg.
   runNewServer

  -- * Interacting with a nameserver
  -- ** Client:
  -- | A client is found at 'Join.NS.Client'.
  -- The protocol is summarised below.

  -- ** Protocol:
  -- | The nameserver communicates with multiple connected clients
  -- asynchronously reading 'ClientMsg's and emitting 'ServerMsg's.
  --
  -- These messages are 'encode'd as 'ByteString's and sent as is
  -- (I.E. NOT newline terminated/ no message headers).
  --
  -- Because all messages are asynchronous, it is the clients responsibility to extract and match
  -- messages returned from the nameserver.
  --
  -- Below, Server->Client messages are described as being 'expected' when they are
  -- expected as a response to some corresponding outgoing Client->Server message.
  -- Other Server->Client messages are 'unexpected' in that they may be recieved
  -- at any time, not as a response to any message.

  -- *** Registration of channelnames:
  -- |
  --
  -- @
  --   Message           : 'Register' CHANNELNAME
  --   Direction         : Client -> Server
  --   Meaning           : Request registration of a channelname.
  --
  --   Expected response : 'RegisterResp' CHANNELNAME success
  --   Direction         : Client <- Server
  --   Meaning           : If successfull, the client has registered the CHANNELNAME and subsequently may recieve unexpected
  --                       'MsgFor CHANNELNAME msg' messages.
  -- @
  --
  -- E.G. "name" is registered to the client.
  --
  -- @
  --   OUT: Register "name"
  --   ...
  --   IN: RegisterResp "name" True
  -- @
  --
  -- E.G. "name" is not registered to the client.
  --
  -- @
  --   OUT: Register "name"
  --   ...
  --   IN: RegisterResp "name" False
  -- @

  -- *** Querying of channelnames:
  -- |
  -- @
  --  Message           : 'Query' CHANNELNAME
  --  Direction         : Client -> Server
  --  Meaning           : Query whether the given channelname exists/ is registered by somebody
  --
  --  Expected response : 'RegisterResp' CHANNELNAME success
  --  Direction         : Client <- Server
  --  Meaning           : The given CHANNELNAME does/ does not exist. If so, the client may now send 'MsgTo CHANNELNAME msg'
  --                      messages.
  -- @
  --
  -- E.G. "name" exists
  --
  -- @
  --   OUT: Query "name"
  --   ...
  --   IN:  QueryResp "name" True
  -- @
  --
  -- E.G. "name" does not exist
  --
  -- @
  --   OUT: Query "name"
  --   ...
  --   IN:  QueryResp "name" True
  -- @

  -- *** Quit messages:
  -- |
  -- @
  --  Message           : ClientQuit'
  --  Direction         : Client -> Server
  --  Meaning           : The client is quitting releasing ownership of any registered channelnames (which may be re-registered)
  --                      and shouldnt be sent any more messages, regardless of whether any are still expected.
  --                      If the client had registered channelnames, then an unexpected 'Unregistered CHANNELNAME CHANNELNAMES'
  --                      message is sent to atleast all clients which knew of the registered names, at most to all clients.
  --
  --  Message           : 'ServerQuit'
  --  Direction         : Client <- Server
  --  Meaning           : The server is quitting. No more messages can be sent or recieved.
  -- @


  -- *** Message forwarding:
  -- |
  -- @
  --  Message           : 'MsgTo' CHANNELNAME msg
  --  Direction         : Client -> Server
  --  Meaning           : The given message should be forwarded to the owner of the CHANNELNAME.
  --                      The client should first establish the CHANNELNAME exists because there is no expected
  --                      response message regardless of success or failure.
  --
  --  Message           : 'MsgFrom' CHANNELNAME msg
  --  Direction         : Client <- Server
  --  Unexpected
  --  Meaning           : The client has previously registered ownership of CHANNELNAME, to which the msg should be
  --                      forwarded to.
  -- @
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
import Join.NS.Util

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
serveClient c s = runCommunicator (_clientHandle c)
                                  1024
                                  (_clientMsgIn c)
                                  (_clientMsgOut c)
                                  (\msgIn -> handleMsgIn msgIn c s)
                                  (\msgOut -> handleMsgOut msgOut c s)

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

