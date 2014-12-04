module Main where

import System.Environment

import Join.NS.Server

main :: IO ()
main = getArgs >>= (runNewServer . read . head)

