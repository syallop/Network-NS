{-# LANGUAGE OverloadedStrings #-}
{-|
Module     : Join.NS.Client
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Defines a simple client to the nameserver defined at 'Join.NS.Server'.

A Client is responsible for handling interactions with a single nameserver.
-}
module Join.NS.Client
  (-- * Running a client
   -- | A new client may be created and ran by calling 'runNewClient' on the
   -- address and port of the nameserver.
   runNewClient
  ,Client()
  ,Callbacks(..)

  -- ** Registering ChannelNames
  ,register

  -- ** Querying ChannelNames
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

import Join.NS.Types

-- | Represents an expectation that the client receive a response
-- of a certain kind.
data ExpectMsg
  -- | Expect a 'ERegistered' response for the given ChannelName.
  = ExpectRegisterResp ChannelName

  -- | Expect a 'EQuery' response for the given ChannelName.
  | ExpectQueryResp ChannelName
  deriving (Eq,Ord)


-- | Cache of known registered and otherwise existing ChannelNames.
-- registered => known
data Cache = Cache
  {_registeredNames :: Set.Set ChannelName -- ^ ChannelNames known to be registered by us.
  ,_knownNames      :: Set.Set ChannelName -- ^ ChannelNames known to be registered by somebody.
  }

emptyCache :: Cache
emptyCache = Cache Set.empty Set.empty

-- | Names have been unregistered and should be removed from the cache.
unregisteredNames :: [ChannelName] -> Cache -> Cache
unregisteredNames ns (Cache r k) = Cache (foldr Set.delete r ns)
                                         (foldr Set.delete k ns)

-- | Register ownership of a new channelname.
registerName :: ChannelName -> Cache -> Cache
registerName n (Cache r k) = Cache (Set.insert n r)
                                   (Set.insert n k)

-- | Register existance of a new channelname.
existsName :: ChannelName -> Cache -> Cache
existsName n (Cache r k) = Cache r (Set.insert n k)

-- | User callback functions asynchronously called on corresponding messages
-- recieved from the server.
data Callbacks = Callbacks
  { -- | Called when a message is recieved for the channelname which the user
    -- must have previously successfully registered.
    _callbackMsgFor       :: ChannelName -> Msg -> IO ()

    -- | Called when the server indicates it is quiting.
  , _callbackServerQuit   :: IO ()

  -- | Called on a non-empty list of ChannelName's which have become unregistered.
  , _callbackUnregistered :: ChannelName -> [ChannelName] -> IO ()
  }

-- | State of a running nameserver client.
data Client = Client
  { -- | Communication handle to nameserver.
    _serverHandle     :: Handle

    -- | IPV4 address of nameserver.
  , _serverAddress    :: String

    -- | PortNumber of nameserver.
  , _serverPort       :: Int

  -- | Cache of known registered and existing channelnames.
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
runClient c = void $ race (readInput "") $ race handleMsgInQueue handleMsgOutQueue
  where
  -- continually read, parse and queue incoming messages in
  -- their corresponding queue.
  readInput :: ByteString -> IO ()
  readInput leftover = do
    msgPart <- hGetSome (_serverHandle c) 1024
    if null msgPart
      then return ()
      else let result = runGetPartial (get :: Get ServerMsg) (leftover `append` msgPart)
              in caseParseResult result

  -- hande the result of an attempt to parse some input
  caseParseResult :: Result ServerMsg -> IO ()
  caseParseResult result = case result of

      -- Parser failed. Continue with leftovers.
      Fail e leftover'
        -> readInput leftover'

      -- Complete ServerMsg read. Queue and continue with any leftovers.
      Done smsg leftover'
        -> do writeChan (_msgIn c) smsg
              readInput leftover'

      -- More input required. Attempt to read more and try again.
      Partial f
        -> do msgPart <- hGetSome (_serverHandle c) 1024
              if null msgPart
                then return ()
                else caseParseResult (f msgPart)

  -- Handle the messages in the input queue until continue=False
  handleMsgInQueue :: IO ()
  handleMsgInQueue = join $ do
    inMsg <- readChan (_msgIn c)
    return $ do
      continue <- handleMsgIn inMsg c
      when continue handleMsgInQueue

  -- Handle the messages in the output queue until continue=False
  handleMsgOutQueue :: IO ()
  handleMsgOutQueue = join $ do
    outMsg <- readChan (_msgOut c)
    return $ do
      continue <- handleMsgOut outMsg c
      when continue handleMsgOutQueue

-- | Handle a single message from a clients input queue,
-- returning a bool indicating whether the connection to the nameserver
-- should be closed.
handleMsgIn :: ServerMsg -> Client -> IO Bool
handleMsgIn smsg c = case smsg of

  -- We have/ havent registered the name
  RegisterResp cName success
    -> do -- cache ownership and/or existance of name
          cache <- takeMVar (_cachedNames c)
          if success
            then putMVar (_cachedNames c) $ registerName cName cache

            -- We failed to register
            -- => Owned by somebody else
            -- => Exists
            else putMVar (_cachedNames c) $ existsName cName cache

          -- pass registration success/failure to any waiting parties
          expectations <- takeMVar (_expectations c)
          let expect = ExpectRegisterResp cName
          case Map.lookup expect expectations of

              -- Nobody expected this response.. continue..
              Nothing -> do putMVar (_expectations c) expectations
                            return True

              Just ls -> do mapM_ (`putMVar` success) ls
                            let expectations' = Map.delete expect expectations
                            putMVar (_expectations c) expectations'
                            return True

  -- The name is/ is not registered by somebody
  QueryResp cName success
    -> do -- cache existance of name
          cache <- takeMVar (_cachedNames c)
          if success
            then putMVar (_cachedNames c) $ existsName cName cache

            -- - We wouldnt have queried if we already knew it existed
            --   => It doesnt exist to be removed.
            -- - We only cache existance
            --
            -- => Nothing to do.
            else putMVar (_cachedNames c) cache

          -- pass existance/ non-existance to any waiting parties
          expectations <- takeMVar (_expectations c)
          let expect = ExpectQueryResp cName
          case Map.lookup expect expectations of

              -- Nobody expected this response.. continue..
              Nothing -> do putMVar (_expectations c) expectations
                            return True

              Just ls -> do mapM_ (`putMVar` success) ls
                            let expectations' = Map.delete expect expectations
                            putMVar (_expectations c) expectations'
                            return True

  -- The server is quitting. Also quit outself.
  ServerQuit
    -> do forkIO $ (_callbackServerQuit . _callbacks $ c)
          return False

  -- A message has been relayed for the channelname.
  MsgFor cName msg
    -> do -- Ensure we only call the handler on channelnames the user has registered
          Cache registeredNames _ <- readMVar (_cachedNames c)
          case Set.member cName registeredNames of

            -- We don't own the channelname.. Drop silently.
            False -> return True
            True  -> do forkIO $ (_callbackMsgFor . _callbacks $ c) cName msg
                        return True

  -- The (previously registered) names are now unregistered.
  Unregistered n ns
    -> do -- Remove all names from cache
          cache <- takeMVar (_cachedNames c)
          let cache' = unregisteredNames (n:ns) cache
          putMVar (_cachedNames c) cache'

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

-- | Request registration of the given ChannelName.
--
-- May block on a response from the nameserver.
--
-- - False => Failure => Somebody else owns the name.
--
-- - True => Success => Future messages sent to the channelname
--   will be passed to the clients callback function.
register :: Client -> ChannelName -> IO Bool
register c cName = do
  cache <- readMVar (_cachedNames c)

  case Set.member cName (_registeredNames cache) of

    -- Already owned by us
    -- => Registration would fail.
    True -> return False

    -- Not owned by us
    False -> case Set.member cName (_knownNames cache) of

        -- Exists => registered by another
        -- => Registration would fail
        True -> return False

        -- Free or just as of yet unseen
        False -> do resp <- newEmptyMVar
                    writeChan (_msgOut c) $ Register cName

                    -- add our expectation
                    expectations <- takeMVar (_expectations c)
                    let expectations' = Map.insertWith (++) (ExpectRegisterResp cName) [resp] expectations
                    putMVar (_expectations c) expectations'

                    -- block on the expected response
                    takeMVar resp

-- | Query whether the given ChannelName is registered.
--
-- May block on a response from the nameserver.
--
-- - False => Is not registered by anybody => May not send messages.
--
-- - True  => Is registered by somebody => May continue to send messages.
query :: Client -> ChannelName -> IO Bool
query c cName = do
  cache <- readMVar (_cachedNames c)

  case Set.member cName (_registeredNames cache) of

      -- We already know the name exists
      True -> return True

      -- Free or just as of yet unseen
      False -> do resp <- newEmptyMVar
                  writeChan (_msgOut c) $ Query cName

                  -- add our expectation
                  expectations <- takeMVar (_expectations c)
                  let expectations' = Map.insertWith (++) (ExpectQueryResp cName) [resp] expectations
                  putMVar (_expectations c) expectations'

                  -- block on the expected response
                  takeMVar resp

-- | Send the message to the given ChannelName.
--
-- - False => We don't know of the name => the message wasnt sent.
--   A successful query (or unsuccesful register) must be made first.
--
-- - True  => The message was sent.
msgTo :: Client -> ChannelName -> ByteString -> IO Bool
msgTo c cName msg = do
  cache <- readMVar (_cachedNames c)

  case Set.member cName (_knownNames cache) of

    -- We don't know of the name, so won't attempt to send to it.
    False -> return False

    -- name exists
    True -> do writeChan (_msgOut c) (MsgTo cName msg)
               return True

-- | Signal that the client should/ is quitting,
-- giving up ownership of any previously registered ChannelNames.
clientQuit :: Client -> IO ()
clientQuit c = writeChan (_msgOut c) ClientQuit

