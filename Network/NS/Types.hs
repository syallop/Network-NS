{-# LANGUAGE DeriveGeneric #-}
{-|
Module     : Network.NS.Types
Copyright  : (c) Samuel A. Yallop, 2014
Maintainer : syallop@gmail.com
Stability  : experimental

Define types used by the nameserver server and client.

-}
module Network.NS.Types
  (Name
  ,Msg

  ,ClientMsg(..)
  ,ServerMsg(..)
  ) where

import Data.ByteString
import Data.Serialize

import GHC.Generics

-- | Unique name which may be owned.
type Name = String

-- | A raw encoded message
type Msg = ByteString

-- | Message sent client -> server
data ClientMsg
  -- | Request registration of a 'Name'.
  -- Responded to by 'RegisterResp'.
  = Register   Name

  -- | Query the existance of a 'Name'.
  -- Responded to by 'QueryResp'.
  | Query      Name

  -- | Request that the 'Msg' is sent to the owner of the 'Name'.
  -- No response.
  | MsgTo      Name Msg

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
  = RegisterResp Name Bool

  -- | Response to 'Query'. Bool indicates success.
  -- True  => Name is registered by somebody.
  -- False => Name is currently free.
  | QueryResp    Name Bool

  -- | Message is relayed for 'Name'.
  -- Counterpart to a valid 'MsgTo'.
  | MsgFor       Name Msg

  -- | Server is quitting.
  | ServerQuit

  -- | A Non-empty list of 'Name's are no longer registered.
  | Unregistered Name [Name]
  deriving Generic
instance Serialize ServerMsg

