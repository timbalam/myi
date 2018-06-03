{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, RankNTypes, ScopedTypeVariables, ExistentialQuantification #-}

-- | Import system, parser and evaluator stage glue
module My.Syntax
  ( runfile
  , runexpr
  , loadfile
  , loadexpr
  , browse
  , checkparams
  , checkimports
  , applybase
  , ScopeError(..)
  , module My.Types
  )
where

--import My.Parser (Parser, parse, readsMy, ShowMy, showMy)
import My.Types.Error
import qualified My.Types.Parser as P
import My.Types
import My.Eval (simplify)
import My.Eval.IO (evalIO)
import My.Base (defaultBase)
import My.Syntax.Parser (Parser, parse, syntax)
import My.Syntax.Import
import My.Syntax.Expr (E, runE, BlockBuilder, block)
import My.Util
import My (ScopeError(..))
import System.IO (hFlush, stdout, FilePath)
import Data.List.NonEmpty (NonEmpty(..), toList)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Map as M
import Data.Bifunctor
import Data.Semigroup ((<>))
import Data.Maybe (fromMaybe)
import Data.Void
import Data.Typeable
import Control.Applicative (liftA2)
import Control.Monad.Reader
import Control.Monad.Catch
import qualified Text.Parsec
import Bound.Scope (instantiate, abstractEither)

  
-- Console / Import --
flushStr :: T.Text -> IO ()
flushStr s =
  T.putStr s >> hFlush stdout

  
readPrompt :: T.Text -> IO (T.Text)
readPrompt prompt =
  flushStr prompt >> T.getLine

-- | Check an expression for free parameters  
checkparams
  :: (Traversable t)
  => t (P.Vis Ident Key)
  -> Either [ScopeError] (t a)
checkparams = first (FreeParam <$>) . closed
  where
  closed :: Traversable t => t b -> Either [b] (t a)
  closed = getCollect . traverse (collect . pure)
  
  
-- | Load library imports
loaddeps :: (MonadIO m, MonadThrow m, Deps r) => [FilePath] -> Src r a -> m a
loaddeps dirs = sourcedeps dirs >=> throwLeftList . checkimports


-- | Load file as an expression.
loadfile
  :: (MonadIO m, MonadThrow m)
  => FilePath
  -> [FilePath]
  -> m (Defns K (Expr K) (Nec Ident))
loadfile f dirs =
  sourcefile f
    >>= loaddeps dirs
    >>= throwLeftList . runE . block
    
    
-- | Load a file and evaluate the entry point 'run'.
runfile
  :: (MonadIO m, MonadThrow m)
  => FilePath
  -- ^ Source file
  -> [FilePath]
  -- ^ Import search path
  -> m (Expr K Void)
  -- ^ Expression with imports substituted
runfile f dirs = 
  loadfile f dirs
    >>= checkfile
    >>= liftIO . evalfile
  where
    checkfile = throwLeftList . applybase defaultBase . Block . fmap P.Priv
    evalfile = return . simplify . (`At` Key (K_ "run"))
    
    
applybase
  :: M.Map Ident (Expr K b)
  -> Expr K (P.Vis (Nec Ident) Key)
  -> Either [ScopeError] (Expr K b)
applybase m = fmap instbase . checkparams . abstbase
  where
    abstbase = abstractEither (\ v -> case v of
      P.Priv (Nec Req i) -> maybe (Right (P.Priv i)) (Left . Just) (M.lookupIndex i m)
      P.Priv (Nec Opt i) -> Left (M.lookupIndex i m)
      P.Pub k -> Right (P.Pub k))
    instbase = instantiate (maybe emptyBlock (snd . (`M.elemAt` m)))
    emptyBlock = Block (Defns [] M.empty)
    
    
-- | Produce an expression
loadexpr
  :: (MonadIO m, MonadThrow m)
  => Src
    (BlockBuilder (Expr K (P.Vis (Nec Ident) Key)))
    (E (Expr K (P.Vis (Nec Ident) Key)))
  -> [FilePath]
  -> m (Expr K (P.Vis (Nec Ident) Key))
loadexpr e dirs =
  loaddeps dirs e
    >>= throwLeftList . runE
  
  
-- | Produce an expression and evaluate entry point 'repr'.
runexpr :: (MonadIO m, MonadThrow m)
  => Src
    (BlockBuilder (Expr K (P.Vis (Nec Ident) Key)))
    (E (Expr K (P.Vis (Nec Ident) Key)))
  -- ^ Syntax tree
  -> [FilePath]
  -- ^ Import search path
  -> m (Expr K Void)
  -- ^ Expression with imports substituted
runexpr e dirs = 
  loadexpr e dirs
    >>= checkexpr
    >>= liftIO . evalexpr
  where
    checkexpr = throwLeftList . applybase defaultBase
    evalexpr = return . simplify
    --evalexpr = evalIO . (`At` Repr)
  
  
-- | Read-eval-print iteration
evalAndPrint
  :: forall m. (MonadIO m, MonadReader [FilePath] m, MonadThrow m)
  => T.Text
  -- ^ Input text
  -> m ()
  -- ^ read-eval-print action
evalAndPrint s = 
  throwLeftMy (parse (syntax <* Text.Parsec.eof) "myi" s)
  >>= \ t -> (ask >>= runexpr (runKr t User))
  >>= (liftIO . putStrLn . showexpr)
  where
    showexpr :: Expr K Void -> String
    showexpr (Prim (Number d))  = show d
    showexpr (Prim (String t))  = show t
    showexpr (Prim (Bool  b))   = show b
    showexpr (Prim (IOError e)) = show e
    showexpr _                  = errorWithoutStackTrace "component missing: repr"

-- | Enter read-eval-print loop
browse
  :: [FilePath]
  -- ^ Import search path
  -> IO ()
  -- ^ Enter read-eval-print loop
browse = runReaderT first where
  first = liftIO (readPrompt ">> ") >>= rest

  rest ":q" = return ()
  rest s = evalAndPrint s >> first
    
   
