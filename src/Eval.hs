{-# LANGUAGE FlexibleContexts #-}

module Eval
  ( evalRval
  )
where
import Control.Monad.Except
  ( throwError
  , catchError
  , MonadError
  )
import Control.Monad.Trans.State
  ( StateT
  , evalStateT
  , execStateT
  , State
  , evalState
  , execState
  , get
  , put
  )
import Control.Monad.Trans.Reader
  ( ReaderT
  , runReaderT
  , mapReaderT
  , ask
  , local
  )
import Control.Monad.Identity
  ( Identity(Identity)
  , runIdentity
  )
import Control.Monad.Trans.Class( lift )
import Control.Applicative( (<|>) )
import Control.Monad( liftM2 )
 
import qualified Types.Parser as T
import qualified Error as E
import Types.Eval

type Getter s a = s -> a
type Setter s t a b = (a -> b) -> s -> t
type Setter' s a = Setter s s a a


view_1 :: Getter (a, b) a
view_1 = fst


over_1 :: Setter (a, b) (c, b) a c
over_1 f (a, b) = (f a, b)


view_2 :: Getter (a, b) b
view_2 = snd


over_2 :: Setter (a, b) (a, c) b c
over_2 f (a, b) = (a, f b)


liftClasses2 :: Applicative f => (IOClasses a -> IOClassses b -> IOClasses c) -> f (IOClasses a) -> f (IOClasses b) -> f (IOClasses c)
liftClasses2 f ma mb = (f <$> ma) `zipClasses` mb


lookupValue :: T.Name Value -> Getter Value (IOExcept Value)
lookupValue k v =
  do{ self <- execNode (unNode v)
    ; runClasses (lookupSelf k) self
    }


evalName :: T.Name T.Rval -> Eval (Scoped (IOClasses (T.Name Value)))
evalName (T.Key r) = fmap . fmap . fmap T.Key $ evalRval r
evalName (T.Ref x) = return . return . return $ T.Ref x


evalRval :: T.Rval -> Eval (Scoped (IOClasses Value))
evalRval (T.Number x) = return . return . return $ Number x
evalRval (T.String x) = return . return . return $ String x
evalRval (T.Rident x) = return . return $ lookupEnv x
evalRval (T.Rroute x) = evalRoute x
  where
    evalRoute :: T.Route T.Rval -> Eval (Scoped (IOClasses Value))
    evalRoute 
    evalRoute (T.Route r x) = (liftA2 . liftA2 viewValueWithKey) (evalName x) (evalRval r)
    evalRoute (T.Atom x) = fmap . fmap (>>= lookupSelf) $ evalName x

evalRval (T.Rnode []) = return . return <$> newSymbol
evalRval (T.Rnode stmts) =
  do{ nn <- newNode
    ; npr <- fmap . fmap (foldr concatNodePair emptyNodePair) $ mapM evalStmt stmts
    ; env <- return askScoped
    ; return . return $
        do{ par <- bindClasses env
          ; let (enode, node) = runScoped npr env'
                env' = concatVtable <$> withNode node <*> pure cur
                cur = fromDiffList (enode ++ toDiffList par)
          ; return . nn $ node
          }
    }
evalRval (T.App x y) =
  do{ vf <- evalRval x
    ; wf <- evalRval y
    ; nn <- newNode
    ; let app v w = nn (unNode w ++ unNode vr)
    ; return $ liftA2 . liftClasses2 app vf wf
    }
evalRval (T.Unop sym x) = fmap . fmap (>>= liftClasses . evalUnop sym) $ evalRval x
  where
    evalUnop :: T.Unop -> Value -> IOExcept Value
    evalUnop sym (Number x) = primitiveNumberUnop sym x
    evalUnop sym (Bool x) = primitiveBoolUnop sym x
    evalUnop sym x = T.Key (unopSymbol sym) `lookupValue` x
evalRval (T.Binop sym x y) =
  do{ vf <- evalRval x
    ; wf <- evalRval y
    ; mv <- liftA2 . liftClasses2 (evalBinop sym) vf wr
    ; return . return $ liftClasses mv
    }
  where
    evalBinop :: T.Binop -> Value -> Value -> IOExcept Value
    evalBinop sym (Number x) (Number y) = primitiveNumberBinop sym x y
    evalBinop sym (Bool x) (Bool y) = primitiveBoolBinop sym x y
    evalBinop sym x y =
      do{ opNode <- unNode <$> T.Key (binopSymbol sym) `lookupValue` x
        ; let opNode' = overNodeWithKey (T.Key rhsSymbol) (const $ return y) opNode
        ; self <- execNode opNode'
        ; runClasses (lookupSelf (T.Key resultSymbol)) self
        }
evalRval (T.Import x) = evalRval x


overNodeWithKey :: T.Name Value -> Setter' Node (IOClasses Value)
overNodeWithKey k f node = return [(k, f)] : node
    
  
unNodeOrEmpty :: MonadError E.Error m => m Value -> m Node
unNodeOrEmpty mv = catchUnboundVar (unNode <$> mv) (return [])

 
viewValueWithKey :: IOClasses (T.Name Value) -> Getter (IOClasses Value) (IOClasses Value)
viewValueWithKey kr vr = liftClasses2 lookupValue kr vr >>= liftClasses
      

overValueWithKey :: Monad m => IOClasses (T.Name Value) -> Eval (Setter' (IOClasses Value) (IOClasses Value))
overValueWithKey kr =
  do{ nn <- newNode
    ; return . $ \ f -> fmap nn . liftClasses2 (flip overNodeWithKey f) kr . fmap unNode
    }
    
    
overOrNewValueWithKey :: Monad m => IOClasses (T.Name Value) -> Eval (Setter' (IOClasses Value) (IOClasses Value))
overOrNewValueWithKey kr =
  do{ nn <- newNode
    ; return $ \ f -> fmap nn . liftClasses2 (flip overNodeWithKey f) kr . unNodeOrEmpty
    }


data LSetter =
    ESetter (T.Ident, Setter' (IOClasses Value) (IOClasses Value))
  | SSetter (IOClasses (T.Name Value, Setter' (IOClasses Value) (IOClasses Value)))
  
  
evalLaddr :: T.Laddress -> Eval (Scoped LSetter)
evalLaddr (T.Lident x) = return . return $ ESetter (x, id)
evalLaddr (T.Lroute r) = evalLroute r
  where
    evalLroute :: T.Route T.Laddress -> Eval (Scoped LSetter)
    evalLroute (T.Route l key) =
      do{ kf <- evalName key
        ; lsetf <- evalLaddr l
        ; vsetf <- fmap return . overOrNewValueWithKey <$> kf
        ; let compose vset (ESetter (x, set)) = ESetter (x, set . vset)
              compose vset (SSetter diffr)    = SSetter (over_2 (. vset) <$> diffr)
        ; return $ liftA2 compose vset lset
        }
    evalLroute (T.Atom k) =
      do{ kf <- evalName k
        ; return . fmap SSetter $ liftA2 . liftA2 (,) kf (pure (pure id))
        }
    
    
unsetNodeWithKey :: T.Name Value -> Node -> Node
unsetNodeWithKey k node = return [(k, deletes k)] : node

    
unsetValueWithKey :: IOClasses (T.Name Value) -> Eval (IOClasses Value -> IOClasses Value)
unsetValueWithKey kr =
  do{ nn <- newNode
    ; return $ fmap nn . liftClasses2 unsetNodeWithKey kr . fmap unNode
    }
    
    
unsetOrEmptyValueWithKey :: IOClasses (T.Name Value) -> Eval (IOClasses Value -> IOClasses Value)
unsetOrEmptyValueWithKey kr =
  do{ nn <- newNode
    ; return $ fmap nn . liftClasses2 unsetNodeWithKey kr . unNodeOrEmpty
    }

    
type NodePair = (EnvNode, Node) 

emptyNodePair = ([], [])

concatNodePair :: NodePair -> NodePair -> NodePair
concatNodePair (enodea, nodea) (enodeb, nodeb) = (enodea++enodeb, nodea++nodeb)
       
evalStmt :: T.Stmt -> Eval (Scoped NodePair)
evalStmt (T.Declare l) = evalUnassign l
  where
    evalUnassign :: T.Laddress -> Eval (Scoped NodePair)
    evalUnassign (T.Lident x) = return . return $ ([(x , deletes x)], [])
    evalUnassign (T.Lroute x) = evalUnassignRoute x
    
    
    evalUnassignRoute :: T.Route T.Laddress -> Eval (Scoped NodePair)
    evalUnassignRoute (T.Route l x) =
      do{ kf <- evalName x
        ; lsetf <- evalLaddr l
        ; vunsetf <- fmap return . unsetOrEmptyValueWithKey $ kf
        ; let apply f (ESetter (x, set)) = ([(x, set f)], [])
              apply f (SSetter diffr)    = ([], [pure . over_2 ($ vunset) <$> diffr])
        ; return $ liftA2 apply vunsetf lsetf
        }
    evalUnassignRoute (T.Atom x) =
      do{ kf <- evalName x
        ; return $
            do{ kr <- kf
              ; return ([], [do{ k <- kr; return [(k, deletes k)] }])
              }
        }
evalStmt (T.Assign l r) = liftA2 (<*>) (evalAssign l) (evalRval r)
evalStmt (T.Unpack r) =
  do{ vf <- evalRval r
    ; return $
        do{ vr <- vf
          ; let selfr =
              do{ v <- vr
                ; liftClasses $ execNode (unNode v)
                }
          ; return $ ([], [toDiffList <$> selfr])
          }
    }
evalStmt (T.Eval r) =
  do{ vf <- evalRval r
    ; return $
        do{ vr <- vf
          ; let selfr =
                  do{ v <- vr
                    ; liftClasses $ execNode (unNode v)
                    }
          ; return ([], [selfr >> return []])
          }
    }
    
    
evalPlainRoute :: T.PlainRoute -> Eval Scoped (Getter (IOClasses Value) (IOClasses Value), Setter' (IOClasses Value) (IOClasses Value))
evalPlainRoute (T.PlainRoute (T.Atom key)) =
  do{ kf <- evalName key
    ; vsetf <- (fmap return . overValueWithKey $ kf)
    ; return $ liftA2 (,) (viewValueWithKey <$> kf) vsetf
    }
evalPlainRoute (T.PlainRoute (T.Route l key)) =
  do{ kr <- evalName key
    ; (lget, lset) <- evalPlainRoute l 
    ; vset <- overValueWithKey kr
    ; return (lget . viewValueWithKey kr, lset . vset)
    }

    
splitPlainRoute :: T.PlainRoute -> Eval Scoped (IOClasses Value -> (IOClasses Value, IOClasses Value))
splitPlainRoute (T.PlainRoute (T.Atom key)) =
  do{ kr <- evalName key
    ; vunset <- unsetValueWithKey kr
    ; return $ \ vr ->
        (viewValueWithKey kr vr, vunset vr)
    }
splitPlainRoute (T.PlainRoute (T.Route l key)) =
  do{ kr <- evalName key
    ; vunset <- unsetValueWithKey kr
    ; (lget, lset) <- evalPlainRoute l
    ; return $ \ vr ->
        (lget (viewValueWithKey kr vr), lset vunset vr)
    }
    

evalAssign :: T.Lval -> Eval (Scoped (IOClasses Value -> NodePair))
evalAssign (T.Laddress x) = 
  do{ lset <- evalLaddr x
    ; return $ \ vr -> case lset of
        ESetter (x, set) -> ([(x, set $ const vr)], [])
        SSetter diffr -> ([], [pure . over_2 ($ const vr) <$> diffr])
    }
evalAssign (T.Lnode xs) =
  do{ unpack <- foldr concatUnpack ((,) emptyNodePair) <$> mapM evalReversibleStmt xs
    ; maybe
        (return $ view_1 . unpack)
        (flip unpackLval unpack)
        (foldr (<|>) Nothing (map collectUnpackStmt xs))
    }
  where
    concatUnpack :: (IOClasses Value -> (NodePair, IOClasses Value)) -> (IOClasses Value -> (NodePair, IOClasses Value)) -> IOClasses Value -> (NodePair, IOClasses Value)
    concatUnpack unpacka unpackb vr = (np `concatNodePair` np', vr'')
      where
        (np, vr') = unpacka vr
        (np', vr'') = unpackb vr'
    
    evalReversibleStmt :: T.ReversibleStmt -> Eval Scoped (IOClasses Value -> (NodePair, IOClasses Value))
    evalReversibleStmt (T.ReversibleAssign keyroute l) = 
      do{ lassign <- evalAssign l 
        ; vsplit <- splitPlainRoute keyroute
        ; return $ over_1 lassign . vsplit
        }
    evalReversibleStmt _ = return $ (,) emptyNodePair
    
    
    collectUnpackStmt :: T.ReversibleStmt -> Maybe T.Lval
    collectUnpackStmt (T.ReversibleUnpack lhs) = Just lhs
    collectUnpackStmt _ = Nothing
    
    
    unpackLval :: T.Lval -> (IOClasses Value -> (NodePair, IOClasses Value)) -> Eval Scoped (IOClasses Value -> NodePair)
    unpackLval l unpack =
      do{ lassign <- evalAssign l
        ; return $ uncurry concatNodePair . over_2 lassign . unpack
        }
        