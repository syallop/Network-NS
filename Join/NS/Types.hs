{-# LANGUAGE DeriveGeneric #-}
{-|
Module     : Join.NS.Types
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Define types used by the nameserver server and client.

-}
module Join.NS.Types where

import Data.ByteString
import Data.Serialize

import GHC.Generics

-- | Name used to uniquely refer to a channel.
type ChannelName = String

-- | Id used to uniquely refer to a client as connected to a server.
type ClientId = Int

-- | A raw encoded message
type Msg = ByteString

-- | Message sent client -> server
data ClientMsg
  -- | Request registration of a 'ChannelName'.
  -- Responded to by 'RegisterResp'.
  = Register   ChannelName

  -- | Query the existance of a 'ChannelName'.
  -- Responded to by 'QueryResp'.
  | Query      ChannelName

  -- | Request that the 'Msg' is sent to the owner of the 'ChannelName'.
  -- No response.
  | MsgTo      ChannelName Msg

  -- | Client is quitting, releasing any registered names.
  -- No response.
  | ClientQuit
  deriving Generic
instance Serialize ClientMsg

-- | Message sent server -> client
data ServerMsg

  -- | Response to 'Register'. Bool indicates success.
  -- True  => Client will now be relayed messages sent to the name.
  -- False => Name is owned by somebody else.
  = RegisterResp ChannelName Bool

  -- | Response to 'Query'. Bool indicates success.
  -- True  => Name is registered by somebody.
  -- False => Name is currently free.
  | QueryResp    ChannelName Bool

  -- | Message is relayed for 'ChannelName'.
  -- Counterpart to a valid 'MsgTo'.
  | MsgFor       ChannelName Msg

  -- | Server is quitting.
  | ServerQuit

  -- | A Non-empty list of 'ChannelName's are no longer registered.
  | Unregistered ChannelName [ChannelName]
  deriving Generic
instance Serialize ServerMsg

