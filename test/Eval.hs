{-# LANGUAGE OverloadedStrings #-}

module Eval
  ( evalTests
  )
  where

import My.Expr
import My.Eval (simplify, K)
import My.Types.Expr
import My.Types.Parser.Short
import qualified My.Types.Parser as P
import My.Parser (ShowMy, showMy)
import qualified My
import My (ScopeError(..))
import Data.List.NonEmpty (NonEmpty)
import Data.Foldable (asum)
import Data.Void
import qualified Data.Map as M
import qualified System.IO.Error as IO
import Control.Exception
import Control.Monad ((<=<))
import Test.HUnit
  
  
banner :: ShowMy a => a -> String
banner r = "For " ++ showMy r ++ ","


run :: Expr K (P.Vis Ident Key) -> IO (Expr K Void)
run = either 
  (ioError . userError . displayException
    . My.MyExceptions :: [ScopeError] -> IO a)
  (return . simplify)
  . My.checkparams
  
  
fails :: ([ScopeError] -> Assertion) -> Expr K (P.Vis Ident Key) -> Assertion
fails f = either f (ioError . userError . shows "Unexpected" 
  . show :: Expr K Void -> Assertion)
  . My.checkparams
  
  
parses :: P.Expr (P.Name Ident Key P.Import) -> IO (Expr K (P.Vis Ident Key))
parses e = My.loadExpr e []


evalTests =
  test
    [ "add" ~: let
        r = (1 #+ 1)
        e = Prim (Number 2)
        in
        parses r >>= run >>= assertEqual (banner r) e
          
    , "subtract" ~: let
        r = (1 #- 2)
        e = (Prim . Number) (-1)
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "public variable" ~: let
        r = (block_ [ self_ "pub" #= 1 ] #. "pub")
        e = Prim (Number 1)
        in parses r >>= run >>= assertEqual (banner r) e
       
    , "private variable ##todo type error" ~: let
        r = (block_ [ env_ "priv" #= 1 ] #. "priv")
        in
        parses r >>= run >>= assertFailure . show
    
    , "private variable access backward" ~: let
        r = (block_ [
          env_ "priv" #= 1,
          self_ "pub" #= env_ "priv"
          ] #. "pub")
        e = Prim (Number 1)
        in parses r >>= run >>= assertEqual (banner r) e
        
    , "private variable access forward" ~: let
        r = (block_ [
          self_ "pub" #= env_ "priv",
          env_ "priv" #= 1
          ] #. "pub")
        e = Prim (Number 1)
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "private access of public variable" ~: let
        r = (block_ [
          self_ "a" #= 1,
          self_ "b" #= env_ "a"
          ] #. "b")
        e = Prim (Number 1)
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "private access in nested scope of public variable" ~: let
        r = (block_ [
          self_ "a" #= 1,
          env_ "object" #= block_ [ self_ "b" #= env_ "a" ],
          self_ "c" #= env_ "object" #. "b"
          ] #. "c")
        e = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "access backward public variable from same scope" ~: let
        r = (block_ [
          self_ "b" #= 2,
          self_ "a" #= self_ "b"
          ] #. "a")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "access forward public variable from same scope" ~: let
        r = (block_ [
          self_ "a" #= self_ "b",
          self_ "b" #= 2
          ] #. "a")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
        
    , "nested public access" ~: let
        r = (block_ [
          self_ "return" #=
            block_ [ self_ "return" #= "str" ] #. "return"
          ] #. "return")
        e = Prim (String "str")
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "unbound variable" ~: let
        r = (block_ [
          self_ "a" #= 2,
          self_ "b" #= env_ "c"
          ] #. "b")
        e = [FreeParam (P.Priv "c")]
        in
        parses r >>= fails (assertEqual (banner r) e)
          
    , "undefined variable ##todo type error" ~: let
        r = block_ [
          self_ "b" #= self_ "a"
          ] #. "b"
        in
        parses r >>= run >>= assertFailure . show
    
    , "application  overriding public variable" ~: let
        r = (block_ [
          self_ "a" #= 2,
          self_ "b" #= self_ "a"
          ] # block_ [ self_ "a" #= 1 ] #. "b")
        e = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "default definition forward" ~: let
        r = (block_ [
          self_ "a" #= self_ "b",
          self_ "b" #= self_ "a"
          ] # block_ [ self_ "b" #= 2 ] #. "a")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
        
    , "default definition backward" ~: let
        r = (block_ [
          self_ "a" #= self_ "b",
          self_ "b" #= self_ "a"
          ] # block_ [ self_ "a" #= 1 ] #. "b")
        e = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) e
         
    , "route getter" ~: let
        r = (block_ [
          self_ "a" #= block_ [ self_ "aa" #= 2 ]
          ] #. "a" #. "aa")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "route setter" ~: let
        r = (block_ [ self_ "a" #. "aa" #= 2 ] #. "a" #. "aa")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
    
    , "application overriding nested property" ~: let
        r = (block_ [
          self_ "a" #= block_ [ self_ "aa" #= 0 ],
          self_ "b" #= self_ "a" #. "aa"
          ] # block_ [ self_ "a" #. "aa" #= 1 ] #. "b")
        e = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) e
     
    , "shadowing update" ~: let
        r = block_ [
          env_ "x" #= block_ [
            self_ "a" #= 1
            ],
          self_ "y" #= block_ [
            env_ "x" #. "b" #= 2,
            self_ "return" #= env_ "x"
            ] #. "return"
          ] #. "y"
        in do
        let
          r1 = r #."a"
          e1 = (Prim . Number) 1
        parses r1 >>= run >>= assertEqual (banner r1) e1
        let
          r2 = r #. "b"
          e2 = (Prim . Number) 2
        parses r2 >>= run >>= assertEqual (banner r2) e2
    
    , "original value is not affected by shadowing" ~: let
        r = (block_ [
          env_ "x" #= block_ [
            self_ "a" #= 2,
            self_ "b" #= 1
            ],
          self_ "x2" #= block_ [
            env_ "x" #. "b" #= 2,
            self_ "return" #= env_ "x"
            ] #. "return",
          self_ "x1" #= env_ "x"
          ])
        in do
        let
          r1 = r #. "x1" #. "b"
          e1 = (Prim . Number) 1
        parses r1 >>= run >>= assertEqual (banner r1) e1
        let
          r2 = r #. "x2" #. "b"
          e2 = (Prim . Number) 2
        parses r2 >>= run >>= assertEqual (banner r2) e2
          
    , "destructuring" ~: let
        r = (block_ [
          env_ "obj" #= block_ [
            self_ "a" #= 2,
            self_ "b" #= 3
            ],
          tup_ [
            self_ "a" #= self_ "da",
            self_ "b" #= self_ "db"
            ] #= env_ "obj"
          ])
        in do
        let
          r1 = r #. "da"
          e1 = (Prim . Number) 2
        parses r1 >>= run >>= assertEqual (banner r1) e1
        let 
          r2 = r #. "db"
          e2 = (Prim . Number) 3
        parses r2 >>= run >>= assertEqual (banner r2) e2
    
    , "destructuring unpack" ~: let
        r = (block_ [
          env_ "obj" #= block_ [
            self_ "a" #= 2,
            self_ "b" #= 3
            ],
          self_ "d" # tup_ [] #= env_ "obj"
          ] #. "d" #. "b")
        e = (Prim . Number) 3
        in parses r >>= run >>= assertEqual (banner r) e
       
    , "nested destructuring" ~: let
        r = (block_ [
          env_ "y1" #= block_ [
            self_ "a" #= block_ [
              self_ "aa" #= 3,
              self_ "ab" #= block_ [ self_ "aba" #= 4 ]
              ]
            ],
          tup_ [
            self_ "a" #. "aa" #= self_ "da",
            self_ "a" #. "ab" #. "aba" #= self_ "daba"
            ] #= env_ "y1",
          self_ "raba" #= env_ "y1" #. "a" #. "ab" #. "aba"
          ])
        in do
        let
          r1 = r #. "raba"
          e1 = (Prim . Number) 4
        parses r1 >>= run >>= assertEqual (banner r1) e1
        let
          r2 = r #. "daba"
          e2 = (Prim . Number) 4
        parses r2 >>= run >>= assertEqual (banner r2) e2
      
    , "self references valid in extensions to an object" ~: let
        r = block_ [
          env_ "w1" #= block_ [ self_ "a" #= 1 ],
          self_ "w2" #= env_ "w1" # block_ [ self_ "b" #= self_ "a" ],
          self_ "w3" #= self_ "w2" #. "a"
          ]
        in do
        let
          r1 = r #. "w2" #. "b"
          e1 = (Prim . Number) 1
        parses r1 >>= run >>= assertEqual (banner r1) e1
        let
          r2 = r #. "w3"
          e2 = (Prim . Number) 1
        parses r2 >>= run >>= assertEqual (banner r2) e2
        
    , "object fields not in private scope for extensions to an object" ~: let
        r = (block_ [
          env_ "a" #= 2,
          env_ "w1" #= block_ [ self_ "a" #= 1 ],
          self_ "w2" #= env_ "w1" # block_ [ self_ "b" #= env_ "a" ]
          ] #. "w2" #. "b")
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
          
    , "access extension field of extended object" ~: let
        r = block_ [
          self_ "w1" #= block_ [ self_ "a" #= 1 ],
          self_ "w2" #= self_ "w1" # block_ [ self_ "b" #= 2 ]
          ] #. "w2" #. "b"
        e = (Prim . Number) 2
        in parses r >>= run >>= assertEqual (banner r) e
        
    , "extension private field scope do not shadow fields of original" ~: let
        r = block_ [
          env_ "original" #= block_ [
            env_ "priv" #= 1,
            self_ "privVal" #= env_ "priv"
            ],
          env_ "new" #= env_ "original" #
            block_ [ env_ "priv" #= 2 ],
          self_ "call" #= env_ "new" #. "privVal"
          ] #. "call"
        v = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) v
          
    , "self referencing definition" ~: let
        r = block_ [
          env_ "y" #= block_ [
            self_ "a" #= env_ "y" #. "b",
            self_ "b" #= 1
            ],
          self_ "call" #= env_ "y" #. "a"
          ] #. "call"
        v = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) v
   
    , "extension referencing original version" ~: let
        r = block_ [
          env_ "y" #= block_ [ self_ "a" #= 1 ],
          self_ "call" #= env_ "y" # block_ [
            self_ "a" #= env_ "y" #. "a"
            ] #. "a"
          ] #. "call"
        v = (Prim . Number) 1
        in parses r >>= run >>= assertEqual (banner r) v
        
    ]