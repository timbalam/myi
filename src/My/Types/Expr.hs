{-# LANGUAGE FlexibleInstances, DeriveFunctor, DeriveFoldable, DeriveTraversable, GeneralizedNewtypeDeriving, RankNTypes, ScopedTypeVariables, UndecidableInstances #-}

-- | Module of my language core expression data types

module My.Types.Expr
  ( Expr(..)
  , Prim(..)
  , PrimTag(..)
  , Defns(..)
  , Node(..)
  , Rec(..), toRec, foldMapBoundRec, abstractRec
  , Tag(..)
  , End(..), fromVoid
  , Ident, Key(..), Unop(..), Binop(..)
  , Var(..), Bound(..), Scope(..)
  , Nec(..), NecType(..)
--  , module My.Types.Prim
  )
  where
  

import My.Types.Parser (Ident, Key(..), Unop(..), Binop(..))
import qualified My.Types.Parser as Parser
--import My.Types.Prim
import Control.Monad (ap)
import Control.Monad.Trans
import Control.Exception (IOException)
import Data.Functor.Classes
import Data.Void
import qualified Data.Map as M
import qualified Data.Map.Merge.Lazy as M
import qualified Data.Text as T
import qualified Data.Set as S
import Data.IORef (IORef)
import System.IO (Handle, IOMode)
import Bound
import Bound.Scope (foldMapScope, foldMapBound, abstractEither)


-- | Represents expression without free variables
newtype End f = End { getEnd :: forall a. f a }


fromVoid :: Functor f => f Void -> End f
fromVoid f = End (absurd <$> f)

toVoid :: End f -> f Void
toVoid (End f) = f


-- | Interpreted my language expression
data Expr k a =
    Prim Prim
  | Var a
  | Block (Defns k (Expr k) a)
  | Expr k a `At` k
  | Expr k a `Fix` k
  | Expr k a `Update` Defns k (Expr k) a
  | Expr k a `AtPrim` PrimTag (Expr k Void)
  deriving (Functor, Foldable, Traversable)
  
  
-- | My language primitives
data Prim =
    Number Double
  | String T.Text
  | Bool Bool
  | IOError IOException
  deriving (Eq, Show)
  
  
data PrimTag a =
    Unop Unop
  | Binop Binop
  | OpenFile IOMode
  | HGetLine Handle
  | HGetContents Handle
  | HPutStr Handle
  | NewIORef
  | GetIORef (IORef a)
  | SetIORef (IORef a)
  deriving Eq
  
  
-- | Set of recursive, extensible definitions / parameter bindings
data Defns k m a =
  Defns
    [Node k (Rec k m a)]
    -- ^ List of local defintions
    (M.Map k (Node k (Rec k m a)))
    -- ^ Publicly visible definitions
  deriving (Functor, Foldable, Traversable)
  
  
-- | Free (Map k) with generalised Eq1 and Show1 instances
-- 
--   Can be a closed leaf value or an open tree of paths representing
--   the defined parts of an incomplete value
data Node k a = 
    Closed a
  | Open (M.Map k (Node k a))
  deriving (Functor, Foldable, Traversable)
  
  
-- | Wraps bindings for a pair of scopes as contained by 'Defns'. 
--    * The outer scope represents indices into the list of private local 
--      definitions
--    * The inner scope represents names of the publicly visible definitions
--      (acting like a self-reference in a class method)
newtype Rec k m a = Rec { getRec :: Scope Int (Scope k m) a }
  deriving (Eq, Eq1, Functor, Foldable, Traversable, Applicative, Monad)
  

-- | Construct a 'Rec' from a classic de Bruijn representation
toRec :: Monad m => m (Var k (Var Int a)) -> Rec k m a
toRec = Rec . toScope . toScope


-- | Fold over bound keys in a 'Rec'  
foldMapBoundRec :: (Foldable m, Monoid r) => (k -> r) -> Rec k m a -> r
foldMapBoundRec g = foldMapScope g (foldMap (foldMapBound g)) . unscope
  . getRec
  
  
-- | Abstract an expression into a 'Rec'
abstractRec
  :: Monad m
  => (b -> Either Int c)
  -- ^ abstract public/env bound variables
  -> (a -> Either k b)
  -- ^ abstract private/self bound variables
  -> m a
  -- ^ Expression
  -> Rec k m c
  -- ^ Expression with bound variables
abstractRec f g = Rec . abstractEither f . abstractEither g

  
instance Ord k => Applicative (Expr k) where
  pure = return
  
  (<*>) = ap
  
instance Ord k => Monad (Expr k) where
  return = Var
  
  Prim p            >>= _ = Prim p
  Var a             >>= f = f a
  Block b           >>= f = Block (b >>>= f)
  e `At` x          >>= f = (e >>= f) `At` x
  e `Fix` m         >>= f = (e >>= f) `Fix` m
  e `Update` b      >>= f = (e >>= f) `Update` (b >>>= f) 
  e `AtPrim` p      >>= f = (e >>= f) `AtPrim` p
  
  
instance (Ord k, Eq a) => Eq (Expr k a) where
  (==) = eq1
  
  
instance Ord k => Eq1 (Expr k) where
  liftEq _  (Prim pa)          (Prim pb)        = pa == pb
  liftEq eq (Var a)           (Var b)           = eq a b
  liftEq eq (Block ba)        (Block bb)        = liftEq eq ba bb
  liftEq eq (ea `At` xa)      (eb `At` xb)      = liftEq eq ea eb &&
    xa == xb
  liftEq eq (ea `Fix` xa)     (eb `Fix` xb)     = liftEq eq ea eb &&
    xa == xb
  liftEq eq (ea `Update` ba)  (eb `Update` bb)  = liftEq eq ea eb &&
    liftEq eq ba bb
  liftEq eq (ea `AtPrim` pa)  (eb `AtPrim` pb)  = liftEq eq ea eb &&
    pa == pb
  liftEq _  _                   _               = False
   
   
instance (Ord k, Show k, Show a) => Show (Expr k a) where
  showsPrec = showsPrec1
   
   
instance (Ord k, Show k) => Show1 (Expr k) where
  liftShowsPrec = go where 
    
    go
      :: forall k a. (Ord k, Show k)
      => (Int -> a -> ShowS)
      -> ([a] -> ShowS)
      -> Int -> Expr k a -> ShowS
    go f g i e = case e of
      Prim p            -> showsUnaryWith showsPrec "Prim" i p
      Var a             -> showsUnaryWith f "Var" i a
      Block b           -> showsUnaryWith f' "Block" i b
      e `At` x          -> showsBinaryWith f' showsPrec "At" i e x
      e `Fix` x         -> showsBinaryWith f' showsPrec "Fix" i e x
      e `Update` b      -> showsBinaryWith f' f' "Update" i e b
      e `AtPrim` p      -> showsBinaryWith f' showsPrec "AtPrim" i e p
      where
        f' :: Show1 f => Int -> f a -> ShowS
        f' = liftShowsPrec f g
        
        --g' :: Show1 f => [f a] -> ShowS
        --g' = liftShowList f g
        
        --f'' :: (Show1 f, Show1 g) => Int -> f (g a) -> ShowS
        --f'' = liftShowsPrec f' g'

        
instance Show (PrimTag a) where
  showsPrec i (Unop op)         = showsUnaryWith showsPrec "Unop" i op
  showsPrec i (Binop op)        = showsUnaryWith showsPrec "Binop" i op
  showsPrec i (OpenFile m)      = showsUnaryWith showsPrec "OpenFile" i m
  showsPrec i (HGetLine h)      = showsUnaryWith showsPrec "HGetLine" i h
  showsPrec i (HGetContents h)  = showsUnaryWith showsPrec "HGetContents" i h
  showsPrec i (HPutStr h)       = showsUnaryWith showsPrec "HPutStr" i h
  showsPrec _ NewIORef          = showString "NewIORef"
  showsPrec i (GetIORef _)      = errorWithoutStackTrace "show: GetIORef"
  showsPrec i (SetIORef _)      = errorWithoutStackTrace "show: SetIORef"
        
        
instance Ord k => Bound (Defns k) where
  Defns en se >>>= f = Defns (((>>>= f) <$>) <$> en) (((>>>= f) <$>) <$> se)
  
  
instance (Ord k, Eq1 m, Monad m) => Eq1 (Defns k m) where
  liftEq eq (Defns ena sea) (Defns enb seb) =
    liftEq f ena enb && liftEq f sea seb
    where f = liftEq (liftEq eq)
    
    
instance (Ord k, Show k, Show1 m, Monad m) => Show1 (Defns k m) where
  liftShowsPrec f g i (Defns en se) = showsBinaryWith (liftShowsPrec f'' g'')
    (liftShowsPrec f'' g'') "Defns" i en se where
        f'' = liftShowsPrec f' g'
        g'' = liftShowList f' g'
        f' = liftShowsPrec f g
        g' = liftShowList f g
        
        
instance Eq k => Eq1 (Node k) where
  liftEq eq (Closed a) (Closed b) = eq a b
  liftEq eq (Open fa)  (Open fb)  = liftEq (liftEq eq) fa fb
  liftEq _  _           _         = False
  
  
instance (Eq k, Eq a) => Eq (Node k a) where
  Closed a == Closed b = a == b
  Open fa  == Open fb  = fa == fb
  _        == _        = False
 

instance Show k => Show1 (Node k) where
  liftShowsPrec f g i (Closed a) = showsUnaryWith f "Closed" i a
  liftShowsPrec f g i (Open m) = showsUnaryWith f'' "Open" i m where
    f'' = liftShowsPrec f' g'
    g' = liftShowList f g
    f' = liftShowsPrec f g
    
    
instance (Show k, Show a) => Show (Node k a) where
  showsPrec d (Closed a) = showParen (d > 10)
    (showString "Closed " . showsPrec 11 a)
  showsPrec d (Open s) = showParen (d > 10)
    (showString "Open " . showsPrec 11 s)
    

instance MonadTrans (Rec k) where
  lift = Rec . lift . lift
  
  
instance Bound (Rec k)
  
  
instance (Show k, Monad m, Show1 m, Show a) => Show (Rec k m a) where
  showsPrec = showsPrec1
    
    
instance (Show k, Monad m, Show1 m) => Show1 (Rec k m) where
  liftShowsPrec f g i m =
    (showsUnaryWith f''' "toRec" i . fromScope . fromScope) (getRec m) where
    f''' = liftShowsPrec  f'' g''
      
    f' = liftShowsPrec f g
    g' = liftShowList f g
    
    f'' = liftShowsPrec f' g'
    g'' = liftShowList f' g'
    
  
-- | Possibly unbound variable
-- 
--   An variable with 'Opt' 'NecType' that is unbound at the top level of
--   a program will be substituted by an empty value
data Nec a = Nec NecType a
  deriving (Eq, Ord, Show)
    
    
-- | Binding status indicator
data NecType = Req | Opt
  deriving (Eq, Ord, Show)
    
    
-- | Expression key type
data Tag k =
    Key Key
  | Symbol k
  | Self
  | RunIO
  | SkipIO
  deriving (Eq, Show)
  
  
-- Manually implemented as monotonicity with Key ordering is relied upon
instance Ord k => Ord (Tag k) where
  compare (Key a)    (Key b)    = compare a b
  compare (Key _)    _          = GT
  compare _          (Key _ )   = LT
  compare (Symbol a) (Symbol b) = compare a b
  compare (Symbol _) _          = GT
  compare _          (Symbol _) = LT
  compare Self       Self       = EQ
  

    
