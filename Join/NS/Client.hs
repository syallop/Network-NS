module Join.NS.Client where

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

-- | Subset of 'ServerMsg' representing messages which are
-- 'expected' as a response to some prior outgoing message.
data ExpectedServerMsg
  = ERegisterResp ChannelName Bool -- ^ 'RegisterResp'
  | EQueryResp    ChannelName Bool -- ^ 'QueryResp'

-- | Subset of 'ServerMsg' representing messages which are
-- 'unexpected' in that they may be recieved at any time
-- - not as a response to a prior outgoing message.
data UnexpectedServerMsg
  = UMsgFor       ChannelName Msg           -- ^ 'MsgFor'
  | UServerQuit                             -- ^ 'ServerQuit'
  | UUnregistered ChannelName [ChannelName] -- ^ 'Unregistered'

-- | Split a ServerMsg into it's corresponding Expected/Unexpected tagged
-- counter-part.
splitByExpectation :: ServerMsg -> Either UnexpectedServerMsg ExpectedServerMsg
splitByExpectation smsg = case smsg of
  RegisterResp cName success
    -> Right $ ERegisterResp cName success
  QueryResp cName success
    -> Right $ EQueryResp cName success

  MsgFor cName msg
    -> Left $ UMsgFor cName msg
  ServerQuit
    -> Left $ UServerQuit
  Unregistered n ns
    -> Left $ UUnregistered n ns

-- | Represents an expectation that the client receive a response
-- of a certain kind.
data ExpectMsg
  -- | Expect a 'ERegistered' response for the given ChannelName.
  = ExpectRegistered ChannelName

  -- | Expect a 'EQuery' response for the given ChannelName.
  | ExpectQuery ChannelName

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

  -- | Queue of parsed messages from the nameserver that may be being waited upon.
  , _msgInExpected    :: Chan ExpectedServerMsg

  -- | Map response message expectations to the locations waiting for the success response value.
  , _expectations     :: MVar (Map.Map ExpectMsg [MVar Bool])

  -- | Queue of parsed messages which are not recieved as a response to a sent message.
  , _msgInUnexpected  :: Chan UnexpectedServerMsg

  -- | Handler function asynchronously called on all 'unexpected' messages.
  , _handleUnexpected :: UnexpectedServerMsg -> IO ()
  }

-- | Cache of known registered and otherwise existing ChannelNames.
data Cache = Cache
  {_registeredNames :: Set.Set ChannelName -- ^ ChannelNames known to be registered by us.
  ,_knownNames      :: Set.Set ChannelName -- ^ ChannelNames known to be registered by somebody.
  }
