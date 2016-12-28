module Test.Eval
  ( assertEval
  , tests
  ) where

import Eval
  ( evalRval
  )
import Types.Eval
  ( emptyVtable
  , liftIO
  , runIOExcept
  , runObjF
  , CEnv(CEnv)
  , Super(Super)
  , Self(Self)
  , Value(..)
  , runEval
  )
import qualified Types.Parser as T
import qualified Error as E 
  
import Test.HUnit
  ( Test(..)
  , Assertion
  , assertEqual
  , assertFailure
  , assertBool
  )

assertEval :: T.Rval -> Value -> Assertion
assertEval r expected =
  runIOExcept
    (do{ res <- runObjF (runEval (evalRval r)) (CEnv $ return emptyVtable) (Self emptyVtable, Super emptyVtable)
       ; liftIO $ assertEqual banner expected res
       })
    (assertFailure . ((banner ++ "\n") ++) . show)
  where
    ref = T.Ref . T.Ident
    banner = "Evaluatiing \"" ++ show r ++ "\""

    
assertError :: String -> T.Rval -> (E.Error -> Bool) -> Assertion
assertError msg r test =
  runIOExcept
    (do{ res <- runObjF (runEval (evalRval r)) (CEnv $ return emptyVtable) (Self emptyVtable, Super emptyVtable)
       ; liftIO $ assertFailure (banner ++ "\nexpected: " ++ msg ++ "\n but got: " ++ show res)
       })
    (assertBool banner . test)
  where
    banner = "Evaluating \"" ++ show r ++ "\"" 


isUnboundVar :: E.Error -> Bool
isUnboundVar (E.UnboundVar _ _) = True
isUnboundVar _ = False
    
tests =
  TestList
    [ TestLabel "add" . TestCase $
        assertEval
          (T.Number 1 `add` T.Number 1)
          (Number 2)
    , TestLabel "subtract" . TestCase $
        assertEval
          (T.Number 1 `sub` T.Number 2)
          (Number (-1))
    , TestLabel "private variables" . TestCase $ 
        assertError
          "Unbound var '.priv'"
          (T.Rnode [lident "priv" `assign` T.Number 1] `rref` "priv")
          isUnboundVar
    , TestLabel "public variables" . TestCase $
        assertEval
          (T.Rnode [lsref "pub" `assign` T.Number 1] `rref` "pub")
          (Number 1)
    , TestLabel "private variable access" . TestCase $
        assertEval
          (T.Rnode
            [ lsref "pub" `assign` rident "priv"
            , lident "priv" `assign` T.Number 1
            ]
          `rref` "pub")
          (Number 1)
    , TestLabel "value keys" . TestCase $
        assertEval
          (T.Rnode [lskey (T.Number 1) `assign` T.String "one"] `rkey` T.Number 1)
          (String "one")
    , TestLabel "symbol keys" . TestCase $
        assertEval
          (T.Rnode
            [ lident "object"
              `assign`
                T.Rnode
                  [ lsref "symbol" `assign` T.Rnode []
                  , lskey (rident "symbol") `assign` T.String "one"
                  ]
            , lsref "a"
              `assign`
                (rident "object" `rkey` (rident "object" `rref` "symbol"))
            ]
          `rref` "a")
          (String "one")
    , TestLabel "node keys" . TestCase $
        assertEval
          (T.Rnode
            [ lident "object" `assign` T.Rnode [lsref "key" `assign` T.Number 1]
            , lskey (rident "object") `assign` T.String "object"
            , lsref "a" `assign` rskey (rident "object")
            ]
          `rref` "a")
          (String "object")
    , TestLabel "unbound variables" . TestCase $
        assertError
          "Unbound var '.c'"
          (T.Rnode 
            [ lsref "a" `assign` T.Number 2
            , lsref "b" `assign` (rident "c" `add` T.Number 1)
            ]
          `rref` "b")
          isUnboundVar
    , TestLabel "undefined variables" . TestCase $
        let node = 
              T.Rnode
                  [ empty (lsref "a")
                  , lsref "b" `assign` T.Number 1
                  ]
        in
          do{ assertEval (node `rref` "b") (Number 1)
            ; assertError "Unbound var '.a'" (node `rref` "a") isUnboundVar
            }
    , TestLabel "undefined keys" . TestCase $
        let node = 
              T.Rnode
                  [ lident "object"
                    `assign` 
                      T.Rnode
                        [ lsref "a1" `assign` T.Rnode []
                        , lsref "b1" `assign` T.Rnode []
                        , lskey (rident "a1") `assign` T.String "exists"
                        ]
                  , lsref "a2" `assign` (rident "object" `rkey` (rident "object" `rref` "a1"))
                  , lsref "b2" `assign` (rident "object" `rkey` (rident "object" `rref` "b1"))
                  ]
        in
          do{ assertEval (node `rref` "a2") (String "exists")
            ; assertError "Unbound key 'object.b1'" (node `rref` "b2") isUnboundVar
            }
    , TestLabel "application  overriding public variables" . TestCase $
        assertEval
          ((T.Rnode 
            [ lsref "a" `assign` T.Number 2
            , lsref "b" `assign` (rsref "a" `add` T.Number 1)
            ]
          `T.App` T.Rnode [lsref "a" `assign` T.Number 1])
          `rref` "b")
          (Number 2)
    , TestLabel "default definition" . TestCase $
        assertEval
          ((T.Rnode
            [ lsref "a" `assign` (rident "b" `sub` T.Number 1)
            , lsref "b" `assign` (rident "a" `add` T.Number 1)
            ]
          `T.App` T.Rnode [ lsref "b" `assign` T.Number 2])
          `rref` "a")
          (Number 1)
    , TestLabel "route getter" . TestCase $
        assertEval
          ((T.Rnode
            [ lsref "a" 
              `assign`
                T.Rnode [ lsref "aa" `assign` T.Number 2 ]
            ]
          `rref` "a")
          `rref` "aa")
          (Number 2)
    , TestLabel "route setter" . TestCase $
        assertEval
          ((T.Rnode
            [ (lsref' "a" `lref` "aa")
              `assign` T.Number 2
            ]
          `rref` "a")
          `rref` "aa")
          (Number 2)
    , TestLabel "public members in scope" . TestCase $
        assertEval
          (T.Rnode
            [ lsref "a" `assign` T.Number 1
            , lsref "b" `assign` rident "a"
            ]
          `rref` "b")
          (Number 1)
    , TestLabel "application overriding nested property" . TestCase $
        assertEval
          ((T.Rnode
            [ lsref "a" `assign` T.Rnode [lsref "aa" `assign` T.Number 0]
            , lsref "b" `assign` (rident "a" `rref` "aa")
            ]
          `T.App`
            T.Rnode [(lsref' "a" `lref` "aa") `assign` T.Number 1])
          `rref` "b")
          (Number 1)
    , TestLabel "shadowing update" . TestCase $
        assertEval
          ((T.Rnode
            [ lident "outer" `assign` T.Rnode [lsref "a" `assign` T.Number 1]
            , lsref "inner"
              `assign`
                T.Rnode
                  [ (lident' "outer" `lref` "b") `assign` T.Number 2
                  , lsref "ab"
                    `assign` 
                      ((rident "outer" `rref` "a") `add` (rident "outer" `rref` "b"))
                  ]
            ]
            `rref` "inner")
            `rref` "ab")
          (Number 3)
    , TestLabel "shadowing update 2" . TestCase $
        assertEval
          (T.Rnode
            [ lident "outer"
              `assign`
                T.Rnode
                  [ lsref "a" `assign` T.Number 2
                  , lsref "b" `assign` T.Number 1
                  ]
            , lsref "inner"
              `assign` T.Rnode [(lsref' "outer" `lref` "b") `assign` T.Number 2]
            , lsref "ab"
              `assign`
                 ((rident "outer" `rref` "a") `add` (rident "outer" `rref` "b"))
            ]
          `rref` "ab")
          (Number 3)
    , TestLabel "destructuring" . TestCase $
        let
          rnode = 
            T.Rnode
              [ lident "obj"
                `assign`
                  T.Rnode
                    [ lsref "a" `assign` T.Number 2
                    , lsref "b" `assign` T.Number 3
                    ]
              , T.Lnode
                  [ plainsref "a" `T.ReversibleAssign` lsref "da"
                  , plainsref "b" `T.ReversibleAssign` lsref "db"
                  ]
                `assign` rident "obj"
              ]
        in
          do{ assertEval (rnode `rref` "da") (Number 2)
            ; assertEval (rnode `rref` "db") (Number 3)
            }
    , TestLabel "destructuring unpack" . TestCase $
        assertEval
          ((T.Rnode
            [ lident "obj"
              `assign`
                T.Rnode
                  [ lsref "a" `assign` T.Number 2
                  , lsref "b" `assign` T.Number 3
                  ]
            , T.Lnode
                [ plainsref "a" `T.ReversibleAssign` lsref "da"
                , T.ReversibleUnpack $ lsref "dobj"
                ]
              `assign` rident "obj"
            ]
          `rref` "dobj")
          `rref` "b")
          (Number 3)
    , TestLabel "nested destructuring" . TestCase $
        assertEval
          (T.Rnode
            [ lident "y1"
              `assign`
                T.Rnode
                  [ lsref "a"
                    `assign`
                      T.Rnode
                        [ lsref "aa" `assign` T.Number 3
                        , lsref "ab" `assign` T.Rnode [lsref "aba" `assign` T.Number 4]
                        ]
                  ]
            , T.Lnode
                [ (plainsref "a" `plainref` "aa") `T.ReversibleAssign` lsref "da"
                , ((plainsref "a" `plainref` "ab") `plainref` "aba") `T.ReversibleAssign` lsref "daba"
                ]
              `assign` rident "y1"
            ]
          `rref` "daba")
          (Number 4)
    , TestLabel "unpack" . TestCase $
        assertEval
          ((T.Rnode
            [ lident "w1" `assign` T.Rnode [lsref "a" `assign` T.Number 1]
            , lsref "w2"
              `assign`
                T.Rnode
                  [ lsref "b" `assign` rident "a"
                  , T.Unpack $ rident "w1"
                  ]
            ]
          `rref` "w2")
          `rref` "b")
          (Number 1)
    ]
  where
    assign x y = T.Assign x (Just x)
    empty x = T.Assign x Nothing
    lident' = T.Lident . T.Ident
    lsref' = T.Lroute . T.Atom . T.Ref . T.Ident
    lskey' = T.Lroute . T.Atom . T.Key
    lref' x y = T.Lroute (x `T.Route` T.Ref (T.Ident y))
    lkey' x y = T.Lroute (x `T.Route` T.Key y)
    lident = T.Laddress . lident'
    lsref = T.Laddress . lsref'
    lskey = T.Laddress . lskey'
    lref x y = T.Laddress (x `lref'` y)
    lkey x y = T.Laddress (x `lkey'` y)
    rident = T.Rident . T.Ident
    rsref = T.Rroute . T.Atom . T.Ref . T.Ident
    rskey = T.Rroute . T.Atom . T.Key
    rref x y = T.Rroute (x `T.Route` T.Ref (T.Ident y))
    rkey x y = T.Rroute (x `T.Route` T.Key y)
    plainsref = T.PlainRoute . T.Atom . T.Ref . T.Ident
    plainskey = T.PlainRoute . T.Atom . T.Key
    plainref x y = T.PlainRoute (x `T.Route` T.Ref (T.Ident y))
    plainkey x y = T.PlainRoute (x `T.Route` T.Key y)
    add = T.Binop T.Add
    sub = T.Binop T.Sub