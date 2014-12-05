{-# LANGUAGE OverloadedStrings #-}
{-|
Module     : Network.NS.Client
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Defines a simple client to the nameserver defined at 'Network.NS.Server'.

A Client is responsible for handling interactions with a single nameserver.


E.G. given:

@
callbacks = Callbacks
  {_callbackMsgFor       = \name msg -> putStrLn $ show name ++ " sent: " ++ show msg
  ,_callbackServerQuit   = putStrLn \"ServerQuit\"
  ,_callbackUnregistered = \name names -> putStrLn $ "Unregistered: " ++ show (name:names)
  }

...

-- Client 1
main = do
  client1 <- runNewClient "127.0.0.1" 5555 callbacks
  isRegistered <- register client1 "name1"
  nameExists   <- query client1 "name2"
  if isRegistered && nameExists
    then msgTo client1 "name2" "hello"
    else return ()

...

-- Client 2
main = do
  client2 <- runNewClient "127.0.0.1" 5555 callbacks
  isRegistered <- register client2 "name2"
  nameExists   <- query client2 "name1"

  if isRegistered && nameExists
    then msgTo client2 "name1" "world"
    else return ()
@

If Network.NS.Server is ran on 127.0.0.1 with './NS 5555'.
then if client1 and client2 are compiled and ran, also at 127.0.0.1:
then the output will be:

@
 Client1: name1 sent "world"
 Client2: name2 sent "hello"
@
-}
module Network.NS.Client
  (-- * Running a client
   runNewClient
  ,Client()
  ,Callbacks(..)
  ,Name
  ,Msg

  -- ** Registering Names
  ,register

  -- ** Querying Names
  ,query

  -- ** Forwarding messages
  ,msgTo

  -- ** Quiting
  ,clientQuit
  ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.Async (race)
import           Control.Monad
import           Data.ByteString                        hiding (foldr)
import qualified Data.Map                        as Map
import           Data.Maybe
import qualified Data.Set                        as Set
import           Data.Serialize
import           Network
import           System.IO                              hiding (hPutStr)

import Prelude hiding (null)

import Network.NS.Types
import Network.NS.Util

-- | Represents an expectation that the client receive a response
-- of a certain kind.
data ExpectMsg
  -- | Expect a 'ERegistered' response for the given Name.
  = ExpectRegisterResp Name

  -- | Expect a 'EQuery' response for the given Name.
  | ExpectQueryResp Name
  deriving (Eq,Ord)



-- | Cache of known registered and otherwise existing Names.
-- registered => known
data Cache = Cache
  {_registeredNames :: Set.Set Name -- ^ Names known to be registered by us.
  ,_knownNames      :: Set.Set Name -- ^ Names known to be registered by somebody.
  }

emptyCache :: Cache
emptyCache = Cache Set.empty Set.empty

-- | Names have been unregistered and should be removed from the cache.
unregisteredNames :: [Name] -> Cache -> Cache
unregisteredNames ns (Cache r k) = Cache (foldr Set.delete r ns)
                                         (foldr Set.delete k ns)

-- | Register ownership of a new name.
registerName :: Name -> Cache -> Cache
registerName n (Cache r k) = Cache (Set.insert n r)
                                   (Set.insert n k)

-- | Register existance of a new name.
existsName :: Name -> Cache -> Cache
existsName n (Cache r k) = Cache r (Set.insert n k)

nameKnown :: Name -> Cache -> Bool
nameKnown n (Cache _ k) = Set.member n k

nameRegistered :: Name -> Cache -> Bool
nameRegistered n (Cache r _) = Set.member n r

-- | User callback functions asynchronously called on corresponding messages
-- recieved from the server.
data Callbacks = Callbacks
  { -- | Called when a message is recieved for the name which the user
    -- must have previously successfully registered.
    _callbackMsgFor       :: Name -> Msg -> IO ()

    -- | Called when the server indicates it is quiting.
  , _callbackServerQuit   :: IO ()

  -- | Called on a non-empty list of Name's which have become unregistered.
  , _callbackUnregistered :: Name -> [Name] -> IO ()
  }

-- | State of a running nameserver client.
data Client = Client
  { -- | Communication handle to nameserver.
    _serverHandle     :: Handle

    -- | IPV4 address of nameserver.
  , _serverAddress    :: String

    -- | PortNumber of nameserver.
  , _serverPort       :: Int

  -- | Cache of known registered and existing names.
  -- Maintained so as to avoid sending unneeded messages
  -- / reject mis-forwarded messages from the server.
  , _cachedNames      :: MVar Cache

  -- | Queue of outgoing messages.
  , _msgOut           :: Chan ClientMsg

  -- | Queue of parsed messages from the nameserver.
  , _msgIn            :: Chan ServerMsg

  -- | Map response message expectations to the locations waiting for the success response value.
  , _expectations     :: MVar (Map.Map ExpectMsg [MVar Bool])

  -- | User Callback functions
  , _callbacks        :: Callbacks
  }

-- | Create a new client, connected to a nameserver at the given address and port.
--
-- Using the given callbacks to handle server messages.
newClient :: String -> Int -> Callbacks -> IO Client
newClient address port cbs = withSocketsDo $ do
  h <- (connectTo address $ PortNumber $ fromIntegral port)
  hSetBuffering h NoBuffering
  Client <$> pure h
         <*> pure address
         <*> pure port
         <*> newMVar emptyCache
         <*> newChan
         <*> newChan
         <*> newMVar Map.empty
         <*> pure cbs

expectRegisterResp :: Client -> Name -> MVar Bool -> IO ()
expectRegisterResp c n resp =
  modifyMVar_ (_expectations c) $ return . Map.insertWith (++) (ExpectRegisterResp n) [resp]

expectQueryResp :: Client -> Name -> MVar Bool -> IO ()
expectQueryResp c n resp =
  modifyMVar_ (_expectations c) $ return . Map.insertWith (++) (ExpectQueryResp n) [resp]

-- | Notify all parties expecting a type of response message of the result.
notifyExpecters :: Client -> ExpectMsg -> Bool -> IO ()
notifyExpecters c expect success =
  modifyMVar_ (_expectations c)
     $ \expectations -> case Map.lookup expect expectations of
         -- Nobody expected this response..
         Nothing -> return expectations

         Just ls -> do mapM_ (`putMVar` success) ls
                       return $ Map.delete expect expectations

-- | Update the namecache with the result of a 'Query'.
-- Nothing done on false because:
--  - We wouldnt have queried if we already knew it existed
--    => We don't have to remove it
--  - We only cache proof of existance, not non-existance
updateCacheQuery :: Client -> Name -> Bool -> IO ()
updateCacheQuery c n exists =
  when exists $ modifyMVar_ (_cachedNames c) $ return . existsName n


-- | Update the namecache with the result of a 'Register'
updateCacheRegister :: Client -> Name -> Bool -> IO ()
updateCacheRegister c n registered =
  modifyMVar_ (_cachedNames c)
    $ return . if registered
                 then registerName n

                 -- We failed to register
                 -- => Owned by somebody else
                 -- => Exists
                 else existsName n


-- | Create and run a new client, connecting to the nameserver at the given
-- address and port.
--
-- Using the given callbacks to handle server messages.
runNewClient :: String -> Int -> Callbacks -> IO Client
runNewClient address port cbs
  | port < 0 = error "Int port number must be > 0"
  | otherwise = do
      c <- newClient address port cbs
      forkFinally (runClient c) (\_ -> hClose (_serverHandle c))
      return c

-- | Concurrently and continually:
-- - Parse and incoming ServerMsg
-- - Handle the queue of valid incoming messages
-- - Handle the queue of valid outgoing ClientMsgs
--
-- Terminating all threads when any returns, which will happen if:
-- - A ClientQuit message is sent
-- - A ServerQuit message is received
-- - The server handle dies
-- - A misc exception is thrown
runClient :: Client -> IO ()
runClient c = runCommunicator (_serverHandle c)
                              1024
                              (_msgIn c)
                              (_msgOut c)
                              (`handleMsgIn` c)
                              (`handleMsgOut` c)

-- | Handle a single message from a clients input queue,
-- returning a bool indicating whether the connection to the nameserver
-- should be closed.
handleMsgIn :: ServerMsg -> Client -> IO Bool
handleMsgIn smsg c = case smsg of

  -- We have/ havent registered the name
  RegisterResp n success
    -> do updateCacheRegister c n success
          notifyExpecters c (ExpectRegisterResp n) success
          return True

  -- The name is/ is not registered by somebody
  QueryResp n success
    -> do updateCacheQuery c n success
          notifyExpecters c (ExpectQueryResp n) success
          return True

  -- The server is quitting. Also quit outself.
  ServerQuit
    -> do forkIO $ (_callbackServerQuit . _callbacks $ c)
          return False

  -- A message has been relayed for the name.
  MsgFor n msg
    -> do -- Ensure we only call the handler on names the user has registered
          Cache registeredNames _ <- readMVar (_cachedNames c)
          when (Set.member n registeredNames)
               (void $ forkIO $ (_callbackMsgFor . _callbacks $ c) n msg)
          return True

  -- The (previously registered) names are now unregistered.
  Unregistered n ns
    -> do -- Remove all names from cache
          modifyMVar_ (_cachedNames c) $ return . unregisteredNames (n:ns)
          forkIO $ (_callbackUnregistered . _callbacks $ c) n ns
          return True

-- | Encode and write outgoing messages to the nameserver.
-- Determining that we should quit communication
-- if we're sending a ClientQuit.
handleMsgOut :: ClientMsg -> Client -> IO Bool
handleMsgOut cmsg c = do
  hPutStr (_serverHandle c) (encode cmsg)
  return $ case cmsg of
    ClientQuit -> False
    _          -> True

-- | Request registration of the given Name.
--
-- May block on a response from the nameserver.
--
-- - False => Failure => Somebody else owns the name.
--
-- - True => Success => Future messages sent to the name
--   will be passed to the clients callback function.
register :: Client -> Name -> IO Bool
register c n = do
  cache <- readMVar (_cachedNames c)
  if nameKnown n cache
    then return False
    else do resp <- newEmptyMVar
            writeChan (_msgOut c) $ Register n
            expectRegisterResp c n resp
            takeMVar resp


-- | Query whether the given Name is registered.
--
-- May block on a response from the nameserver.
--
-- - False => Is not registered by anybody => May not send messages.
--
-- - True  => Is registered by somebody => May continue to send messages.
query :: Client -> Name -> IO Bool
query c n = do
  cache <- readMVar (_cachedNames c)
  if nameRegistered n cache
      then return True
      else do resp <- newEmptyMVar
              writeChan (_msgOut c) $ Query n
              expectQueryResp c n resp
              takeMVar resp

-- | Send the message to the given Name.
--
-- - False => We don't know of the name => the message wasnt sent.
--   A successful query (or unsuccesful register) must be made first.
--
-- - True  => The message was sent.
msgTo :: Client -> Name -> Msg -> IO Bool
msgTo c n msg = do
  cache <- readMVar (_cachedNames c)
  if nameKnown n cache
    then do writeChan (_msgOut c) $ MsgTo n msg
            return True
    else return False

-- | Signal that the client should/ is quitting,
-- giving up ownership of any previously registered Names.
clientQuit :: Client -> IO ()
clientQuit c = writeChan (_msgOut c) ClientQuit

