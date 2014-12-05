{-# LANGUAGE OverloadedStrings #-}
{-|
Module     : Network.NS.Server
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Defines a quick and dirty nameserver which acts as a central authority for
mapping 'Name's to client's which have registered them.
The nameserver supports querying the existance of names as well as forwarding
ByteString 'encode'd messages.

A client for the nameserver is found at 'Network.NS.Client'.
-}
module Network.NS.Server
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
  -- | A client is found at 'Network.NS.Client'.
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

  -- *** Registration of names:
  -- |
  --
  -- @
  --   Message           : 'Register' NAME
  --   Direction         : Client -> Server
  --   Meaning           : Request registration of a name.
  --
  --   Expected response : 'RegisterResp' NAME success
  --   Direction         : Client <- Server
  --   Meaning           : If successfull, the client has registered the NAME and subsequently may recieve unexpected
  --                       'MsgFor NAME msg' messages.
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

  -- *** Querying of names:
  -- |
  -- @
  --  Message           : 'Query' NAME
  --  Direction         : Client -> Server
  --  Meaning           : Query whether the given name exists/ is registered by somebody
  --
  --  Expected response : 'RegisterResp' NAME success
  --  Direction         : Client <- Server
  --  Meaning           : The given NAME does/ does not exist. If so, the client may now send 'MsgTo NAME msg'
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
  --  Meaning           : The client is quitting releasing ownership of any registered names (which may be re-registered)
  --                      and shouldnt be sent any more messages, regardless of whether any are still expected.
  --                      If the client had registered names, then an unexpected 'Unregistered NAME NAMES'
  --                      message is sent to atleast all clients which knew of the registered names, at most to all clients.
  --
  --  Message           : 'ServerQuit'
  --  Direction         : Client <- Server
  --  Meaning           : The server is quitting. No more messages can be sent or recieved.
  -- @


  -- *** Message forwarding:
  -- |
  -- @
  --  Message           : 'MsgTo' NAME msg
  --  Direction         : Client -> Server
  --  Meaning           : The given message should be forwarded to the owner of the NAME.
  --                      The client should first establish the NAME exists because there is no expected
  --                      response message regardless of success or failure.
  --
  --  Message           : 'MsgFrom' NAME msg
  --  Direction         : Client <- Server
  --  Unexpected
  --  Meaning           : The client has previously registered ownership of NAME, to which the msg should be
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

import Network.NS.Types
import Network.NS.Util

-- | Id used to uniquely refer to a client as connected to a server.
type ClientId = Int

-- | Map clientId's to the list of Names they own
-- and vice-versa.
newtype NamesMap = NamesMap
  {unNamesMap :: (Map.Map Name     ClientId
                 ,Map.Map ClientId [Name]
                 )
  }

emptyNamesMap :: NamesMap
emptyNamesMap = NamesMap (Map.empty,Map.empty)

-- | Map a ClientId <-> [Name] overwriting any previous associations
insert :: ClientId -> [Name] -> NamesMap -> NamesMap
insert cId ns (NamesMap (nameToId,idToNames)) =
  let newNameToId = Map.fromList [(n,cId) | n <- ns]
      nameToId'   = newNameToId `Map.union` nameToId
      idToNames'  = Map.insertWith (++) cId ns idToNames
     in NamesMap (nameToId',idToNames')

-- | Lookup the ClientId who has registered the given Name.
lookupClientId :: Name -> NamesMap -> Maybe ClientId
lookupClientId n (NamesMap (nameToId,_)) = Map.lookup n nameToId

-- | Lookup all Names registered by the given ClientId.
lookupNames :: ClientId -> NamesMap -> Maybe [Name]
lookupNames cId (NamesMap (_,idToNames)) = Map.lookup cId idToNames

-- | Remove a ClientId and all of their registered Names from the map.
-- Unaltered when clientId does not exist.
removeClient :: ClientId -> NamesMap -> NamesMap
removeClient cId m@(NamesMap (nameToId,idToNames)) = case lookupNames cId m of
  Nothing -> m -- Client not in map
  Just ns
    -> let nameToId'  = foldr (\name nameToId' -> Map.delete name nameToId') nameToId ns
           idToNames' = Map.delete cId idToNames
          in NamesMap (nameToId',idToNames')


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

   -- | Map clientIds <-> Names
  , _names :: MVar NamesMap
  }

newServer :: IO Server
newServer = Server <$> newMVar Map.empty
                   <*> newMVar emptyNamesMap

-- | Add a new client to the server, returning the ClientConn.
addClientConn :: ClientId -> Handle -> Server -> IO ClientConn
addClientConn cId cHandle server = modifyMVar (_clientConns server) $ \cs -> do
  c  <- ClientConn <$> pure cId
                   <*> pure cHandle
                   <*> newChan
                   <*> newChan
  return (Map.insert cId c cs,c)

-- | Lookup the ClientConn associated with an Id.
lookupClientConn :: ClientId -> Server -> IO (Maybe ClientConn)
lookupClientConn cId s = readMVar (_clientConns s) >>= return . Map.lookup cId

-- | Queue a ServerMsg to be sent to the client.
sendToClient :: ClientConn -> ServerMsg -> IO ()
sendToClient c smsg = writeChan (_clientMsgOut c) smsg

-- | Queue a ClientMsg read from the client.
receivedFromClient :: ClientConn -> ClientMsg -> IO ()
receivedFromClient c cmsg = writeChan (_clientMsgIn c) cmsg

-- | Queue a ServerMsg to be sent to all clients.
broadcastToClients :: Server -> ServerMsg -> IO ()
broadcastToClients s smsg = readMVar (_clientConns s) >>= mapM_ (`sendToClient` smsg) . Map.elems

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
  -- of any unregistered names and stop communication.
    ClientQuit
      -> stopAfter
       $ do nm <- takeMVar (_names s)

            -- Remove client from server
            modifyMVar_ (_clientConns s) $ return . Map.delete (_clientId c)

            case lookupNames (_clientId c) nm of

                -- Should be unreachable
                Nothing -> error "Client not registered in server state"

                -- Client hasnt registered any names
                Just []
                  -> putMVar (_names s) nm

                -- Client registered >= 1 name
                Just (n:ns)
                  -> do let nm' = removeClient (_clientId c) nm
                        putMVar (_names s) nm'

                        broadcastToClients s (Unregistered n ns)

    -- Client requests registration of a Name
    Register n
      -> continueAfter
       $ do ns <- takeMVar (_names s)
            case lookupClientId n ns of

              -- name already taken
                Just _
                  -> do putMVar (_names s) ns
                        sendToClient c (RegisterResp n False)

                -- name free => registered to client
                Nothing
                  -> do putMVar (_names s) (insert (_clientId c) [n] ns)
                        sendToClient c (RegisterResp n True)

    -- Client queries the existance of a name
    Query n
      -> continueAfter
       $ withMVar (_names s) $ \ns -> case lookupClientId n ns of
             Nothing -> sendToClient c (QueryResp n False)
             Just _  -> sendToClient c (QueryResp n True)

    -- Client requests that the Msg is sent to the owner of Name
    MsgTo n msg
      -> continueAfter
       $ withMVar (_names s) $ \ns -> case lookupClientId n ns of
             Nothing -> return () -- Name not registered.. Drop silently.
             Just targetCId
               -> do targetClient <- fromJust <$> lookupClientConn targetCId s
                     sendToClient targetClient (MsgFor n msg)

-- | Encode and write outgoing messages to the client.
-- Determining that we should quit communication
-- if we're sending a ServerQuit.
handleMsgOut :: ServerMsg -> ClientConn -> Server -> IO Bool
handleMsgOut smsg c s = do
  hPutStr (_clientHandle c) (encode smsg)
  return $ case smsg of
      ServerQuit -> False
      _          -> True

