{-# LANGUAGE OverloadedStrings, RankNTypes, ScopedTypeVariables, DeriveFunctor #-}

-- | Effectful evaluator for my language expressions
module My.Eval.IO
  ( evalIO
  , wrapIOPrim
  , handleSelf
  )
where

import My.Types.Expr
import My.Types.Error
import My.Types.Interpreter
import My.Eval (K, toDefns, Comp, Susp(..) , Free(..), eval)
import My.Util ((<&>))
import Data.List.NonEmpty (NonEmpty)
import Data.Bifunctor
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Void
import Control.Applicative (liftA2)
import Control.Monad (join, (<=<), ap)
import Control.Monad.Trans
import Control.Exception (IOException, catch)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Functor.Identity (Identity(..))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO (Handle, IOMode, withFile)
import Bound (Scope(..), instantiate)


type Expr' k = Expr k Identity
  
-- | Effectful evaluation
evalIO 
  :: Expr' K Void -> IO ()
evalIO = run . go . eval
  where
    run :: Comp (Expr' K Void) (Expr' K Void) (IO ()) -> IO ()
    run (Pure e) = e
    run (Free s) = errorWithoutStackTrace ("evalIO: unhandled " ++ show (yield s))
    
    go
      :: Comp (Expr' K Void) (Expr' K Void) (Expr' K Void)
      -> Comp (Expr' K Void) (Expr' K Void) (IO ())
    go (Free (Susp (Expr (Identity (e `AtPrim` p))) k)) = getIOPrim e p (run . go . k)
    go e                                                = const (return ()) <$> e


-- | Run an IO-performing primitive action. A closed expression is required
--   when saving to mutable variables.
--
--   IOPrim values should only occur inside the hidden 'RunIO' of a
--   promise.
--
--   IOPrim values are evaluated by running the IOPrim action, calling
--   the 'onSuccess' or 'onError' handlers on the attached my expression,
--   then passing the 'RunIO' component of the returned promise to the
--   input continuation.
getIOPrim
  :: forall r . Expr' K Void
  -> IOPrimTag (Expr' K Void)
  -> (Expr' K Void -> IO r)
  -> Comp (Expr' K Void) (Expr' K Void) (IO r)
getIOPrim e p k = case p of
  -- file io
  OpenFile mode ->
    open . T.unpack . text <$> (eval . Expr . return) (e `At` Key (K_ "filename"))
    where
      open :: FilePath -> IO r
      open f = iotry (withFile f mode (\ h -> ok (handleSelf h)))
        
  HGetLine h -> (pure . iotry)
    (do
      t <- T.hGetLine h
      ok ((M.singleton (Key (K_ "val")) . Closed . lift . Expr . return . Prim) (Text t)))
        
  HGetContents h -> (pure . iotry)
    (do
      t <- T.hGetContents h
      ok ((M.singleton (Key (K_ "val")) . Closed . lift . Expr . return . Prim) (Text t)))
    
  HPutStr h -> put . text <$> (eval . Expr . return) (e `At` Key (K_ "val"))
    where
      put s = iotry (T.hPutStr h s >> ok M.empty)
    
  NewMut -> (pure . iotry)
    (do
      err <- (newIORef . Expr . return) (e `At` Key (K_ "val"))
      ok (iorefSelf err))
    
  GetMut ref -> (pure . iotry)
    (do
      v <- readIORef ref
      ok ((M.singleton (Key (K_ "val")) . Closed . lift) (absurd <$> v)))
  
  SetMut ref -> (pure . iotry)
    ((writeIORef ref . Expr . return) (e `At` Key (K_ "val")) >> ok M.empty)
        
  where
    text a = case runIdentity (runExpr a) of
      Prim (Text t) -> t
      _ -> errorWithoutStackTrace "eval: text type"
      
    iotry :: IO r -> IO r
    iotry x = catch x (\ err ->
      k (skip
        (Key (K_ "onError"))
        ((M.singleton (Key (K_ "err")) . Closed . lift . Expr . return . Prim) (IOError err))
        e))
    
    ok
      :: (forall x . M.Map K (Node K (Scope K (Expr' K) x)))
      -> IO r
    ok defs = k (skip (Key (K_ "onSuccess")) defs e)
    
    skip
      :: K
      -> (forall x. M.Map K (Node K (Scope K (Expr' K) x)))
      -> Expr' K a
      -> Expr' K a
    skip x defs e = (Expr . return) ((Expr . return) ((Expr . return) (e `Update` toDefns
      (defs <> (M.singleton (Builtin SkipAsyncS) 
        . Closed . lift . Expr . return . Block . toDefns)
        (dftCallbacks <> (M.singleton (Key (K_ "then"))
          . Closed . Scope . skip x defs . return . B) (Builtin SelfS))))
            `At` x) `At` Key (K_ "then"))
   
    iorefSelf :: IORef (Expr' K Void) -> M.Map K (Node K (Scope K (Expr' K) a))
    iorefSelf x = M.fromList [
      (Key (K_ "set"), member (SetMut x)),
      (Key (K_ "get"), member (GetMut x))
      ]
      where member = Closed . lift . wrapIOPrim
    

  
-- | Symbol
symbolSelf :: Monad m => K -> M.Map K (Node K (Scope K (Expr K m) a))
symbolSelf k = M.fromList [
  (Key (K_ "set"),
    (Closed . Scope . Expr . return)
      ((return . B) (Key (K_ "target")) `Update`
        (Fields . M.singleton k . Closed . return . B) (Key (K_ "value")))),
  (Key (K_ "get"),
    (Closed . Scope . Expr . return) ((return . B) (Key (K_ "target")) `At` k))
  ]
  

-- | IO
handleSelf :: Monad m => Handle -> M.Map K (Node K (Scope K (Expr K m) a))
handleSelf h = M.fromList [
  (Key (K_ "getLine"), member (HGetLine h)),
  (Key (K_ "getContents"), member (HGetContents h)),
  (Key (K_ "putStr"), member (HPutStr h))
  ]
  where member = Closed . lift . wrapIOPrim
  
  
-- | 'wrapIOPrim p' wraps a 'IOPrimTag' in a default expression with a 
--   'then' component.
wrapIOPrim
  :: Monad m => IOPrimTag (Expr K m Void) -> Expr K m a
wrapIOPrim p = (Expr . return . Block . toDefns)
  (dftCallbacks <> (M.singleton (Key (K_ "then")) . Closed . Scope . Expr . return)
    ((return . B) (Builtin SelfS) `AtPrim` p))
  
  
-- | Wrap a my language IO action in a promise interface that passes
--   dispatches 'onSuccess' and 'onError' continuations to the action.
dftCallbacks :: Monad m => M.Map K (Node K (Scope K (Expr K m) a))
dftCallbacks = M.fromList [
  (Key (K_ "onError"),
    (Closed . Scope . Expr . return . Block . Fields
      . M.singleton (Key (K_ "then")) . Closed . return . B) (Builtin SkipAsyncS)),
  (Key (K_ "onSuccess"),
    (Closed . Scope . Expr . return . Block . Fields
      . M.singleton (Key (K_ "then")) . Closed . return . B) (Builtin SkipAsyncS))
  ]