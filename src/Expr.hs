{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveFunctor, DeriveFoldable, DeriveTraversable, OverloadedStrings, FlexibleInstances, UndecidableInstances, MultiParamTypeClasses, FunctionalDependencies #-}
module Expr
  ( expr
  , stmt
  , program
  , ScopeError(..)
  , Check
  , MonadResolve(..)
  , MonadAbstract(..)
  )
where

import qualified Types.Parser as P
import Types.Expr
import Util

import Control.Applicative( liftA2, (<|>) )
import Control.Monad.Trans( lift )
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
import Data.Foldable( fold )
--import Data.Maybe( fromMaybe )
import Data.Semigroup
import Data.Typeable
import Data.List( elemIndex )
import Data.List.NonEmpty( NonEmpty, toList )
import Data.Void
import Control.Monad.Free
import Control.Monad.State
import Control.Monad.Reader
import qualified Data.Map as M
import qualified Data.Set as S

  
-- | check for free parameters in expression
data ScopeError =
    FreeSym P.Symbol
  | FreeParam Ident
  deriving (Eq, Show, Typeable)
  
  
type Check = Collect (NonEmpty ScopeError)


-- | Resolve symbols and variables and assign unique ids
class Monad m => MonadResolve k m | m -> k where
  resolveSymbol :: P.Symbol -> m (Maybe (Key k))
  
  localSymbols :: [P.Symbol] -> m a -> m a
  
  
tag :: MonadResolve k m => P.Tag -> m (Check (Key k))
tag (P.Ident l) = (return . pure) (Ident l)
tag (P.Symbol s) = maybe def pure <$> resolveSymbol s where
  def = (collect . pure) (FreeSym s)
  
  
class Monad m => MonadAbstract m where
  abstractIdent :: Ident -> m (Maybe Int)
  
  localIdents :: [Ident] -> m a -> m a
  
  envInds :: m [Int]
  
  
ident :: MonadAbstract m => Ident -> m (Check Int)
ident x = maybe def pure <$> abstractIdent x where
  def = (collect . pure) (FreeParam x)


-- | build executable expression syntax tree
expr
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.Syntax
  -> m (Check (ExprK k (VarK k)))
expr = go where
  go (P.IntegerLit i) = (return . pure . Number) (fromInteger i)
  go (P.NumberLit d) = (return . pure) (Number d)
  go (P.StringLit t) = (return . pure) (String t)
  go (P.Var x) = (Var <$>) <$> var x
  go (P.Get (e `P.At` x)) = liftA2 (liftA2 At) (go e) (tag x)
  go (P.Block b) = block b
  go (P.Extend e b) = liftA2 (liftA2 Update) (go e) (block b)
  go (P.Unop op e) = go e <&> ((`At` Unop op) <$>)
  go (P.Binop op e w) = liftA2 (liftA2 updatex) (go e <&> ((`At` Binop op) <$>)) (go w) where
    updatex e w =
      (e `Update` (Block [] . M.singleton (Ident "x") . Closed) (lift w))
        `At` Ident "return"
  
  var = bitraverse2 ident tag
  
  block
    :: (Ord k, MonadAbstract m, MonadResolve k m)
    => P.Block P.Tag P.Syntax
    -> m (Check (ExprK k (VarK k)))
  block (P.Tup xs) = (tup' . fold <$>) <$> traverse2 stmt xs
  block (P.Rec xs) = rec xs
    >>= either (return . collect) ((pure <$>) . rec') . getCollect

  tup' :: M k (Nctx k (Expr k) a) -> Expr k a
  tup' se = Block [] (mextract <$> getM se)
  
  rec'
    :: (Ord k, MonadAbstract m)
    => Rctx k (Nctx k (Expr k) (Vis Int a))
    -> m (Expr k (Vis Int a))
  rec' (ectx, sctx) = flip Block se . (en ++) <$> pen where
    en = mextract <$> ectx
    se = mextract <$> getM sctx
    pen = (Closed . return . Priv <$>) <$> envInds

      
program
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.Program
  -> m (Check (ExprK k a))
program (P.Program l) = (program' <$>) <$> rec (toList l)
  where
    program' (ectx, sctx) =
      Block (mextract <$> ectx) (mextract <$> getM sctx)
    
      

-- | Traverse to find corresponding env and field substitutions
type Nctx k m a = Free (M k) (Rec k m a)
type NctxK k m a = Nctx (Key k) m a
  
  
stmt 
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.Stmt P.Tag P.Syntax
  -> m (Check (MK k (NctxK k (ExprK k) (VarK k))))
stmt = go where
  go (P.Pun p) = (setpun <$>) <$> punpath p
  go (p `P.Set` e) = liftA2 (liftA2 setstmt) (relpath p) (expr e)
      
  setpun
    :: Ord k
    => P.Path (Key k) (Vis (Ident, Int) (Key k)) 
    -> MK k (NctxK k (ExprK k) (VarK k))
  setpun p = (intro (singletonm . public . first fst <$> p) . lift
    . extract) (Var . first snd <$> p)
    
  setstmt
    :: Ord k
    => P.Path (Key k) (Key k)
    -> ExprK k a 
    -> MK k (NctxK k (ExprK k) a)
  setstmt p e = intro (singletonm <$> p) (lift e)
  
  
punpath
  :: (MonadAbstract m, MonadResolve k m)
  => P.VarPath
  -> m (Check (P.Path (Key k) (Vis (Ident, Int) (Key k))))
punpath =
  bitraverseFree2 tag (bitraverse2 (remember2 ident) (tag))
  where
    remember2 :: (Functor f, Functor g) => (a -> f (g b)) -> a -> f (g (a, b))
    remember2 f a = ((,) a <$>) <$> f a
  

relpath
  :: (MonadAbstract m, MonadResolve k m)
  => P.RelPath
  -> m (Check (P.Path (Key k) (Key k)))
relpath = bitraverseFree2 tag tag

  
public :: Vis Ident (Key k) -> (Key k)
public (Pub t) = t
public (Priv l) = (Ident l)

  
extract :: P.Path k (Expr k a) -> Expr k a
extract = iter (\ (e `P.At` t) -> e `At` t)


type Rctx k a = ([a], M k a)
type RctxK k a = Rctx (Key k) a


rec
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => [P.RecStmt P.Tag P.Syntax]
  -> m (Check (RctxK k (NctxK k (ExprK k) a)))
rec xs = (localIdents ls . localSymbols ss) ((fold <$>) <$> traverse2 recstmt xs)
  where
    (ss, ls) = recctx xs
  
  

recstmt
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.RecStmt P.Tag P.Syntax
  -> m (Check (RctxK k (NctxK k (ExprK k) a)))
recstmt = go where
  go (P.DeclSym _) = return (pure mempty)
  go (P.DeclVar l) = (declvar <$>) <$> relpath (P.Ident <$> l)
  go (l `P.SetRec` e) = liftA2 (<*>) (setexpr l) (expr e)
  
  declvar
    :: (Ord k, Monoid m)
    => P.Path (Key k) (Key k)
    -> ([NctxK k (ExprK k) a], m)
  declvar p =
    ([(Pure . abst . extract) (Var . Pub <$> p)], mempty)
    
    
abst :: Monad m => m (Vis Int k) -> Rec k m a
abst e = toRec (e >>= \ v -> case v of
  Pub k -> return (B k)
  Priv i -> return (F (B i)))
  
  
setexpr
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.SetExpr P.Tag
  -> m (Check (ExprK k (VarK k) -> RctxK k (NctxK k (ExprK k) a)))
setexpr = go where
  go (P.SetPath p) = (setpath <$>) <$> varpath p
  go (P.Decomp stmts) = (snd <$>) <$> usedecomp stmts
  go (P.SetDecomp l stmts) = liftA2 (liftA2 setdecomp)
    (setexpr l)
    (usedecomp stmts)
    
  setdecomp
    :: Semigroup m
    => (Expr k a -> m)
    -> ([k], Expr k a -> m)
    -> Expr k a -> m
  setdecomp f (ks, g) = f . rest <> g where
    rest = flip (foldl Fix) ks
    
  usedecomp
    :: (Ord k, MonadAbstract m, MonadResolve k m)
    => [P.Stmt P.Tag (P.SetExpr P.Tag)]
    -> m (Check ([Key k], ExprK k (VarK k) -> RctxK k (NctxK k (ExprK k) a)))
  usedecomp stmts = (fold <$>) <$> traverse2 usematchstmt stmts
  

  
varpath 
  :: (MonadAbstract m, MonadResolve k m)
  => P.VarPath -> m (Check (P.Path (Key k) (VarK k)))
varpath = bitraverseFree2 tag (bitraverse2 ident tag)

  
setpath
  :: Ord k
  => P.Path (Key k) (VarK k)
  -> ExprK k (VarK k)
  -> RctxK k (NctxK k (ExprK k) a)
setpath p e = case k of
  Pub t@(Ident _) ->  ([(Pure . abst) (Var k)], singletonm t n)
  Pub t -> ([], singletonm t n)
  Priv _ -> ([n], emptym)
  where
    (k, n) = intro ((,) <$> p) (abst e)
      
        
usematchstmt
  :: (Ord k, MonadAbstract m, MonadResolve k m)
  => P.Stmt P.Tag (P.SetExpr P.Tag) 
  -> m (Check ([Key k], ExprK k (VarK k) -> RctxK k (NctxK k (ExprK k) a)))
usematchstmt = go where
  go (P.Pun p) = (matchpun <$>) <$> punpath p
  go (p `P.Set` l) = liftA2 (liftA2 matchset)
    (setexpr l)
    ((useextractrel <$>) <$> relpath p)
    where 
      matchset f = ((f .) <$>)
  
  matchpun
    :: Ord k
    => P.Path (Key k) (Vis (Ident, Int) (Key k))
    -> ([Key k], ExprK k (VarK k) -> RctxK k (NctxK k (ExprK k) a))
  matchpun p = (setpath (first snd <$> p) .) <$> useextractrel r where
      r = public . first fst <$> p
  
  useextractrel :: P.Path k k -> ([k], Expr k a -> Expr k a)
  useextractrel p = ([root p], extract . (<$> p) . At)
  

root :: P.Path a b -> b
root = iter (\ (l `P.At` _) -> l)


-- | Traverse to find symbols and declared labels
recctx :: [P.RecStmt P.Tag a] -> ([P.Symbol], [Ident])
recctx = foldMap recstmtctx where
  recstmtctx (P.DeclSym s) = ([s], [])
  recstmtctx (P.DeclVar l) = ([], [root l])
  recstmtctx (l `P.SetRec` _) = ([], setexprctx l)
    
  setexprctx :: P.SetExpr P.Tag -> [Ident]
  setexprctx (P.SetPath p) = pathctx p
  setexprctx (P.Decomp xs) = foldMap matchstmtctx xs
  setexprctx (P.SetDecomp p xs) = setexprctx p <> foldMap matchstmtctx xs
  
  pathctx :: P.VarPath -> [Ident]
  pathctx = maybe [] pure . maybeIdent . root
  
  matchstmtctx (P.Pun p) = pathctx p
  matchstmtctx (_ `P.Set` l) = setexprctx l

  
maybeIdent (Pub (P.Ident l)) = Just l
maybeIdent (Pub (P.Symbol _)) = Nothing
maybeIdent (Priv l) = Just l

  
-- | Bindings context
data DefnError =
    OlappedMatch [P.Stmt P.Tag (P.SetExpr P.Tag)]
  | OlappedSet (P.Block P.Tag P.Syntax)
  | OlappedVis [Ident]
  | OlappedSyms [P.Symbol]

  
data An f a = An a (An f a) | Un (f (An f a))
  
  
an :: (Semigroup (f (An f a)), Monoid (f (An f a))) => a -> An f a
an a = An a mempty


iterAn :: (Functor f, Semigroup a) => (f a -> a) -> An f a -> a
iterAn f (An a an) = a <> iterAn f an
iterAn f (Un fa) = f (iterAn f <$> fa)


instance Semigroup (f (An f a)) => Semigroup (An f a) where
  An x a <> b = An x (a <> b)
  a <> An x  b = An x (a <> b)
  Un fa <> Un fb = Un (fa <> fb)
    
    
instance (Semigroup (f (An f a)), Monoid (f (An f a))) => Monoid (An f a) where
  mempty = Un mempty
  
  mappend = (<>)
  
  
-- | Wrapped map with a modified semigroup instance
newtype M k a = M { getM :: M.Map k a }
  deriving (Functor, Foldable, Traversable)
  
instance (Semigroup a, Ord k) => Semigroup (M k a) where
  M ma <> M mb = M (M.unionWith (<>) ma mb)
  
  
instance (Semigroup a, Ord k) => Monoid (M k a) where
  mempty = emptym
  
  mappend = (<>)
  
  
instance (Semigroup (M k (Free (M k) a)), Ord k) => Semigroup (Free (M k) a) where
  Free ma <> Free mb = Free (ma <> mb)
  a <> _ = a
  
  
emptym :: M k a
emptym = M M.empty
  
singletonm :: k -> a -> M k a
singletonm k = M . M.singleton k

intro :: P.Path k (Free (M k) b -> c) -> b -> c
intro p = iter (\ (f `P.At` t) -> f . Free . singletonm t) p . Pure

mextract :: Free (M k) a -> Node k a
mextract f = iter (Open . getM) (Closed <$> f)

type MK k = M (Key k)
  
  


