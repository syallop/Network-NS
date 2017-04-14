# A quick and dirty NameServer
This module defines a simple NameServer, a central authority
allowing clients to register ownership of names which can then
be queried and passed arbitrary messages.

## Running a Server
A nameserver can either be started as part of a Haskell program
by calling ‘runNewServer portN’ from ‘Network.NS.Server’
or by calling ‘NS portN’ at a command line.

## Running a Client
[‘Network.NS.Client’](/Network/NS/Client.hs).
defines a simple client, providing functions for:
- Creating clients
- Registering names
- Querying names
- Sending messages to names

Usage is described more in the
[‘documentation’](/Network/NS/Client.hs).

### Example
E.G. given:

```haskell
-- Functions asynchronously called by the client when the corresponding event occurs.
callbacks = Callbacks
  {_callbackMsgFor       = \name msg -> putStrLn $ show name ++ " sent: " ++ show msg
  ,_callbackServerQuit   = putStrLn "ServerQuit"
  ,_callbackUnregistered = \name names -> putStrLn $ "Unregistered: " ++ show (name:names)
  }

...

-- Client 1
main = do

  -- Create a new client
  client1      <- runNewClient "127.0.0.1" 5555 callbacks

  -- Register “name1”
  isRegistered <- register client1 "name1"

  -- Confirm “name2” exists
  nameExists   <- query client1 "name2"

  -- Send a message to the other name
  if isRegistered && nameExists
    then msgTo client1 "name2" "hello"
    else return ()

...

-- Client 2
main = do

  -- Create a new client
  client2      <- runNewClient "127.0.0.1" 5555 callbacks

  -- Register “name2”
  isRegistered <- register client2 "name2"

  -- Confirm “name1” exists
  nameExists   <- query client2 "name1"

  -- Send a message to the other name
  if isRegistered && nameExists
    then msgTo client2 "name1" "world"
    else return ()
```

If Network.NS.Server is ran on 127.0.0.1 with './NS 5555'.
then if client1 and client2 are compiled and ran, also at 127.0.0.1:
then the output at each site should be:


Client1:
```
name1 sent "world"
```
Client2:
```
name2 sent "hello"
```

## Protocol
The protocol is described in the documentation for
[‘Network.NS.Server’](/Network/NS/Server.hs).

## Behaviour
- All messages are routed through the nameserver (clients are invisible to each other)
- All connections take place over TCP
- Names can not be unregistered and are owned for the duration of the connection
  at which point they are made available again.

