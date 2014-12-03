module Join.NS.Server
  (
  ) where

import Control.Concurrent

import qualified Data.Map as Map
import System.IO

import Join.NS.Types

-- | Store data related to a connected client.
data ClientConn = ClientConn
  {_clientId     :: ClientId       -- ^ Globally unique clientId
  ,_clientHandle :: Handle         -- ^ Communication handle
  ,_clientMsgIn  :: Chan ClientMsg -- ^ Queue of incomming messages
  ,_clientMsgOut :: Chan ServerMsg -- ^ Queue of outgoing messages
  }


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


-- | State of a running nameserver.
data Server = Server
  { -- | All connected clients, indexed by their id
    _clientConns  :: MVar (Map.Map ClientId ClientConn)

   -- | Map clientIds <-> channelNames
  , _channelNames :: MVar ChannelNamesMap
  }

