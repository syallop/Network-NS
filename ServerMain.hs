module Main where

import System.Environment

import Network.NS.Server

main :: IO ()
main = getArgs >>= (runNewServer . read . head)

