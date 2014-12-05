{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}
module Network.NS.Util
  (runCommunicator
  ,readInput
  ,handleChan

  ,continueAfter
  ,stopAfter
  ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.Async (race)
import           Control.Monad
import           Data.ByteString                        hiding (foldr)
import           Data.Maybe
import           Data.Serialize
import           Data.Unique
import           Network
import           System.IO                              hiding (hPutStr)

import Prelude hiding (null)

-- | Run some abstract 'communicator' by concurrently:
-- - Reading, parsing and queueing incoming messages
-- - Handling parsed in-messages with some function fIn
-- - Handling parsed out-messages with some function fOut
--
-- Termination happens to all threads if any returns, which will happen if:
-- - EOF is read on the handle
-- - fIn returns False
-- - fOut returns False
-- - A misc exception is thrown
runCommunicator :: forall i o. (Serialize i, Serialize o)
                => Handle -- ^ Handle to incomming messages
                -> Int    -- ^ Maximum number of bytes to read at a time
                -> Chan i -- ^ Channel of parsed input messages
                -> Chan o -- ^ Channel of parsed output messages
                -> (i -> IO Bool) -- ^ Handle parsed input, deciding whether to continue.
                -> (o -> IO Bool) -- ^ Handle parsed output, deciding whether to continue.
                -> IO ()
runCommunicator h bytes chanIn chanOut fIn fOut =
    void $ race (readInput h bytes chanIn)
          $ race (handleChan fIn chanIn)
                  (handleChan fOut chanOut)

-- | Continually read, parse and queue incoming messages until EOF.
readInput :: forall t. Serialize t
          => Handle     -- ^ Open communication handle
          -> Int        -- ^ Number of bytes to try and read at a time
          -> Chan t     -- ^ Channel of types 't' to parse input into
          -> IO ()
readInput h bytes chan = readInput' h bytes chan ""
  where
    readInput' h bytes chan leftover = do
      msgPart <- hGetSome h bytes
      if null msgPart
        then return () -- EOF, handle unexpectedly died.
        else let result = runGetPartial (get :: Get t) (leftover `append` msgPart)
                in caseParseResult result

    -- Handle the result of an attempt to parse some input
    caseParseResult :: Result t -> IO ()
    caseParseResult result = case result of

        -- Parser failed. Continue with leftovers.
        Fail e leftover'
          -> readInput' h bytes chan leftover'

        -- Complete message read. Queue and continue with any leftovers.
        Done msg leftover'
          -> do writeChan chan msg
                readInput' h bytes chan leftover'

        -- More input required. Attempt to read more and try again.
        Partial f
          -> do msgPart <- hGetSome h bytes
                if null msgPart
                  then return ()
                  else caseParseResult (f msgPart)

-- | Continually read values from a Chan and pass
-- them to an IO function which decides whether to continue or not.
handleChan :: forall t. Serialize t
           => (t -> IO Bool) -- ^ Handle chan message, returning whether we should continue
           -> Chan t         -- ^ Channel of messages to read from
           -> IO ()
handleChan f chan = join $ do
  msg <- readChan chan
  return $ do
    continue <- f msg
    when continue (handleChan f chan)

-- Return True after running (and discarding the result) of an io action
continueAfter :: IO a -> IO Bool
continueAfter io = void io >> return True

-- Return False after running (and discarding the result) of an io action
stopAfter :: IO a -> IO Bool
stopAfter io = void io >> return False

