{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}
module Join.NS.Util
  (readInput
  ,handleChan
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

-- | Continually read, parse and queue incomming messages until EOF.
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

