module Main where


import Version( myiReplVersion )
import Lib
  ( loadProgram
  , browse
  , ShowMy(..)
  )
  
import System.Environment ( getArgs )
import Data.List.NonEmpty( NonEmpty(..) )

  
main :: IO ()
main =
  do
    args <- getArgs
    case args of
      [] -> runRepl
      (file:args) -> runOne (file:|args)
      
      

runRepl :: IO ()
runRepl = browse

    
runOne :: NonEmpty String -> IO ()
runOne (file:|_args) =
  loadProgram file >>= putStrLn . showMy
