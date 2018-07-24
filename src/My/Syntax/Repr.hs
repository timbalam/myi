{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveFunctor, DeriveFoldable, DeriveTraversable, RankNTypes, FlexibleContexts, FlexibleInstances, TypeFamilies, MultiParamTypeClasses, StandaloneDeriving, ScopedTypeVariables, TupleSections #-}

-- | Module with methods for desugaring and checking of syntax to the
--   core expression
module My.Syntax.Repr
  ( E
  , runE
  , BlockBuilder(..)
  , DefnError(..)
  , buildBlock
  )
where

import qualified My.Types.Parser as P
import My.Types.Repr
import My.Types.Classes (MyError(..))
import My.Types.Interpreter (K)
import qualified My.Types.Syntax.Class as S
import qualified My.Syntax.Import as S (Deps(..))
import My.Util
import Control.Applicative (liftA2, liftA3, Alternative(..))
import Control.Monad.Trans (lift)
import Control.Monad (ap)
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
import Data.Coerce (coerce)
import Data.Foldable (fold, toList)
import Data.Semigroup
import Data.Functor.Plus (Plus(..), Alt(..))
import Data.Maybe (mapMaybe, fromMaybe)
import Data.Typeable
import Data.List (elemIndex, nub)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Void
import GHC.Exts (IsString(..))
import Control.Monad.Free
--import Control.Monad.State
import qualified Data.Map as M
import qualified Data.Set as S
import Bound.Scope (abstractEither, abstract)


-- | Errors from binding definitions
data DefnError =
    OlappedMatch (P.Path P.Key)
  -- ^ Error if a pattern specifies matches to non-disjoint parts of a value
  | OlappedSet P.VarPath
  -- ^ Error if a Block assigns to non-disjoint paths
  | OlappedVis Ident
  -- ^ Error if a name is assigned both publicly and privately
  deriving (Eq, Show, Typeable)
  
  
instance MyError DefnError where
  displayError (OlappedMatch p) = "Ambiguous destructuring of path " ++ show p
  displayError (OlappedSet p) = "Ambiguous assignment to path " ++ show p
  displayError (OlappedVis i) = "Variable assigned with multiple visibilities " ++ show i

  
-- | Wrapper for applicative syntax error checking
newtype E a = E (Collect [DefnError] a)
  deriving (Functor, Applicative)
  
runE :: E a -> Either [DefnError] a
runE (E e) = getCollect e

instance Semigroup a => Semigroup (E a) where
  (<>) = liftA2 (<>)
  
instance Monoid a => Monoid (E a) where
  mempty = pure mempty
  mappend = liftA2 mappend
  
instance S.Self a => S.Self (E a) where
  self_ = pure . S.self_
  
instance S.Local a => S.Local (E a) where
  local_ = pure . S.local_
  
instance S.Field a => S.Field (E a) where
  type Compound (E a) = E (S.Compound a)
  
  e #. k = e <&> (S.#. k)

instance Num a => Num (E a) where
  fromInteger = pure . fromInteger
  (+) = liftA2 (+)
  (-) = liftA2 (-)
  (*) = liftA2 (*)
  negate = fmap negate
  abs = fmap abs
  signum = fmap signum
  
instance Fractional a => Fractional (E a) where
  fromRational = pure . fromRational 
  (/) = liftA2 (/)
  
instance IsString a => IsString (E a) where
  fromString = pure . fromString
  
instance S.Lit a => S.Lit (E a) where
  unop_ op = fmap (S.unop_ op)
  binop_ op a b = liftA2 (S.binop_ op) a b


-- | Core representation builder
type instance S.Member (E (Open (Tag k) a)) = E (Open (Tag k) a)

instance S.Block (E (Open (Tag k) (P.Vis (Nec Ident) a))) where
  type Rec (E (Open (Tag k) (P.Vis (Nec Ident) a))) =
    BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
  block_ b = (Defns . Block) (block_ b)
  
instance (S.Self a, S.Local a) => S.Tuple (E (Open (Tag k) a)) where
  type Tup (E (Open (Tag k) a)) = TupBuilder (Open (Tag k) a)
  tup_ b = Defn . fmap lift <$> buildTup b
  
instance S.Extend (E (Open (Tag k) a)) where
  type Ext (E (Open (Tag k) a)) = E (Open (Tag k) a)
  e # w = liftA2 Update e w
  
instance S.Block (E (M.Map Ident (Bindings (Open (Tag k)) (Nec Ident)))) where
  type Rec (E (M.Map Ident (Bindings (Open (Tag k)) (Nec Ident)))) =
    BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
  block_ = buildBlock
  
type instance S.Member (E (M.Map Ident (Bindings (Open (Tag k)) (P.Vis (Nec Ident) Ident)))) = 
  E (Open (Tag k) (P.Vis (Nec Ident) Ident))
  
instance S.Block (E (M.Map Ident (Bindings (Open (Tag k)) (P.Vis (Nec Ident) Ident)))) where
  type Rec (E (M.Map Ident (Bindings (Open (Tag k)) (P.Vis (Nec Ident) Ident)))) =
    BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
  block_ b = fmap P.Priv <$> buildBlock b
  
instance S.Tuple (E (M.Map Ident (Open (Tag k) (P.Vis (Nec Ident) Ident)))) where
  type Tup (E (M.Map Ident (Open (Tag k) (P.Vis (Nec Ident) Ident)))) =
    TupBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
  tup_ = buildTup

type instance S.Member (BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))) =
  E (Open (Tag k) (P.Vis (Nec Ident) Ident))

instance Ord k => S.Deps (BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))) where
  prelude_ (BlockB g xs) b = b' S.#: b
    where
      -- Build a pattern that introduces a local alias for each
      -- component of the imported prelude Block
      b' :: BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
      b' = S.tup_ (foldr puns S.empty_ ns) S.#= S.block_ (BlockB g xs)
      
      puns :: (S.Splus a, S.Local a) => Ident -> a -> a
      puns i a = S.local_ i S.#: a

      -- identifiers for public component names of prelude Block
      ns = names g
    
  
  
-- | Build a set of definitions for a 'Tuple' expression
buildTup
  :: Ord k => TupBuilder (E (Open (Tag k) a))
  -> E (M.Map Ident (Bindings (Open (Tag k)) a))
buildTup (TupB g xs) = liftA2 substexprs (lnode g) (rexprs xs)
  where
    substexprs pubn vs = pubn' where
      pubn' = M.map (abstractSuper . lift . f) pubn
      f = (>>= bind (return . Parent) (vs'!!))
      
      vs' = map (Local <$>) vs
  
    -- Right-hand side values to be assigned
    rexprs :: [E a] -> E [a]
    rexprs xs = sequenceA xs
    
    -- Left-hand side paths determine constructed shape
    lnode:: Ord k => Builder Paths -> E (M.Map Ident (Open (Tag k) (Bind Ident Int)))
    lnode g = (E . validatepub . unPaths) (build g [0..])
  
  
-- | Represent whether a free variable can be bound locally
data Bind a b = Parent a | Local b

bind :: (a -> c) -> (b -> c) -> Bind a b -> c
bind f _ (Parent a) = f a
bind _ g (Local a) = g a
  
    
-- | Validate that a finished tree has unambiguous paths and construct 
-- an expression that reflects the tree of assigned values.
--
-- If there are any ambiguous paths, returns them as list of 'OlappedSet'
-- errors.
--
-- Paths with missing 'Nothing' values represent paths that must not be assigned
-- and are not included in the constructed 'Node'.
--
-- Nested definitions shadow the corresponding 'Super' bound definitions ones on
-- a path basis - e.g. a path declared x.y.z = ... will shadow the .z component of
-- the .y component of the x variable. 
validatepub, validatepriv
  :: Ord k => M.Map Ident (An (Maybe a))
  -> Collect [DefnError] (M.Map Ident (Open (Tag k) (Bind Ident a)))
validatepub = validate P.Pub (Pure . P.K_)
validatepriv = validate P.Priv Pure

validate
  :: Ord k => (P.Path a -> P.VarPath)
  -> (Ident -> P.Path a)
  -> M.Map Ident (An (Maybe b))
  -> Collect [DefnError] (M.Map Ident (Open (Tag k) (Bind Ident b)))
validate f = M.traverseMaybeWithKey . go
  where
    go _ _ (An a Nothing) = pure (Var . Local <$> a)
    go g k (An a (Just b)) = (collect . pure . OlappedSet . f) (g k) *> go g k b
    go g k (Un m) =
      Just . Update (Var (Parent k)) . Defn . Block . M.mapKeysMonotonic Key
        . M.map (fmap Local . abstractSuper . lift)
        <$> M.traverseMaybeWithKey (go (Free . P.At (g k) . P.K_)) m
     
     
-- | Bind parent- scoped public variables to the future 'Super' value
abstractSuper
  :: Ord k => Scope Self (Open (Tag k)) (Bind Ident a)
  -> Bindings (Open (Tag k)) a
abstractSuper s = abstractEither (bind Left Right) (s >>>= f) where
  f (Parent k) = (selfApp . Var) (Parent Super) `At` Key k
  f (Local a)  = return (Local a)
  
-- | Bind local- scoped public variables to the future 'Self' value
abstractSelf
  :: Ord k => Open (Tag k) (Bind a (P.Vis b Ident))
  -> Scope Self (Open (Tag k)) (Bind a b)
abstractSelf o = abstractEither (P.vis Right Left) (o >>= f) where
  f (Parent a)         = return (P.Priv (Parent a))
  f (Local (P.Priv b)) = return (P.Priv (Local b))
  f (Local (P.Pub k))  = (selfApp . Var) (P.Pub Self) `At` Key k
        
    
-- | Abstract builder
data Builder (group :: * -> *) = B_
  { size :: Int
    -- ^ number of values to assign / paths
  , build :: forall a . [a] -> group a
    -- ^ builder function that performs assignment
  , names :: [Ident]
    -- ^ list of top-level names in assignment order
  }
  
instance Alt group => Semigroup (Builder group) where
  B_ sz1 b1 n1 <> B_ sz2 b2 n2 =
    B_ (sz1 + sz2) b (n1 <> n2)
    where
      b :: forall a . [a] -> group a
      b xs = let (x1, x2) = splitAt sz1 xs in b1 x1 <!> b2 x2
  
instance Plus group => Monoid (Builder group) where
  mempty = B_ 0 (const zero) mempty
  mappend = (<>)
  
hoistBuilder :: (forall x . g x -> f x) -> Builder g -> Builder f
hoistBuilder f (B_ sz b n) = B_ sz (f . b) n

    
-- | A 'Path' is a sequence of fields
data Path =
  PathB
    (forall m a . (MonadFree (M.Map Ident) m, Alt m) => m a -> m a)
    -- ^ push additional fields onto path
    Ident
    -- ^ top-level field name

instance S.Self Path where self_ i = PathB id i
  
instance S.Local Path where local_ i = PathB id i
  
instance S.Field Path where
  type Compound Path = Path
  PathB f a #. k = PathB (f . wrap . M.singleton k) a

    
-- | A set of paths
newtype Paths a = Paths
  { unPaths
      :: forall m. (MonadFree (M.Map Ident) m, Alt m)
      => M.Map Ident (m (Maybe a)) 
  }
  deriving Functor
  
instance Alt Paths where Paths m1 <!> Paths m2 = Paths (M.unionWith (<!>) m1 m2)

instance Plus Paths where zero = Paths M.empty

intro :: Path -> Builder Paths
intro (PathB f n) = B_ 1 (\ xs -> Paths ((M.singleton n . f . pure . Just . head) xs)) [n]


-- | A punned assignment statement
type Pun = S.Sbi (,)

-- | A 'Tuple' is a group of paths with associated values
data TupBuilder a =
  TupB
    (Builder Paths)
    -- ^ constructs tree of fields assigned by statements in a tuple
    [a]
    -- ^ values in assignment order
  
pun :: Pun Path a -> TupBuilder a
pun (S.Sbi (p, a)) = TupB (intro p) [a]
  
instance S.Self a => S.Self (TupBuilder a) where self_ i = pun (S.self_ i)
  
instance S.Local a => S.Local (TupBuilder a) where local_ i = pun (S.local_ i)
  
instance S.Field a => S.Field (TupBuilder a) where
  type Compound (TupBuilder a) = Pun Path (S.Compound a)
  b #. k = pun (b S.#. k)
  
instance S.Let (TupBuilder a) where
  type Lhs (TupBuilder a) = Path
  type Rhs (TupBuilder a) = a
  p #= a = TupB (intro p) [a]
    
instance S.Sep (TupBuilder a) where 
  TupB g1 a1 #: TupB g2 a2 = TupB (g1 <> g2) (a1 <> a2)
    
instance S.Splus (TupBuilder a) where
  empty_ = TupB mempty mempty
  
    
-- | Build definitions set for a syntax 'Block' expression
buildBlock
  :: forall k . Ord k
  => BlockBuilder (Open (Tag k) (P.Vis (Nec Ident) Ident))
  -> E (M.Map Ident (Bindings (Open (Tag k)) (Nec Ident)))
buildBlock (BlockB g xs) = liftA2 substenv (ldefngroups g) (rexprs xs)
  where
    substenv (locn, pubn) vs = pubn' where
      
      -- public variable map, with local-, self- and super-bindings
      pubn' :: M.Map Ident (Bindings (Open (Tag k)) (Nec Ident))
      pubn' = M.map (abstractSuper . abstractSelf . abstractLet . f) pubn
      
      abstractLet = Let (fmap Local <$> locv) . abstractLocal ls
      
      -- local variables ordered by bound index
      locv :: Ord k => [Scope Int (Open (Tag k)) (P.Vis (Nec Ident) Ident)]
      locv = map (\ k -> M.findWithDefault (pure (P.Pub k)) k locn') ls
      
      -- local variable map, with parent-env scoped variables
      locn' :: Ord k => M.Map Ident (Scope Int (Open (Tag k)) (P.Vis (Nec Ident) Ident))
      locn' = M.map (freeParent . abstractLocal ls . f) locn 
      
      -- private parent bindable variables are scoped to enclosing env
      freeParent = fmap (bind (P.Priv . Opt) id)
      
      -- abstract local-bound variables in an expression
      abstractLocal ls = abstract (\ x -> case x of
        Local (P.Priv x) -> maybe Nothing Just (nec (`elemIndex` ls) (`elemIndex` ls) x)
        _                -> Nothing)
      
      -- insert values by list index
      f :: forall b. Open (Tag k) (Bind b Int)
        -> Open (Tag k) (Bind b (P.Vis (Nec Ident) Ident))
      f = (>>= bind (return . Parent) (vs'!!))
      
      -- private free variables are local
      vs' :: forall b. [Open (Tag k) (Bind b (P.Vis (Nec Ident) Ident))]
      vs' = fmap Local <$> vs
      
    
    -- Use the source order for private definition list to make predicting
    -- output expressions easier (alternative would be sorted order)
    ls = nub (names g)
    
    rexprs :: forall a . E [a] -> E [a]
    rexprs = id 
    
    ldefngroups
      :: forall k . Ord k
      => Builder VisPaths
      -> E 
        ( M.Map Ident (Open (Tag k) (Bind Ident Int))
        , M.Map Ident (Open (Tag k) (Bind Ident Int))
        )
    ldefngroups g = (E . validatevis . build g) [0..size g]
    
    
-- | Validate that a group of private/public definitions are disjoint, and
--   extract 'Node' expressions for each defined name.
validatevis
  :: Ord k => VisPaths x
  -> Collect [DefnError]
    ( M.Map Ident (Open (Tag k) (Bind Ident x))
    , M.Map Ident (Open (Tag k) (Bind Ident x))
    )
validatevis v = viserrs *> liftA2 (,) (validatepriv locn) (validatepub pubn)
  where
    -- Generate errors for any identifiers with both public and private 
    -- definitions
    viserrs = M.foldrWithKey
      (\ l (a, b) e -> e *> (collect . pure) (OlappedVis l))
      (pure ())
      (M.intersectionWith (,) locn pubn)
      
    locn = unPaths (local v)
    pubn = unPaths (self v)


-- | Paths partitioned by top-level visibility
data VisPaths a = VisPaths { local :: Paths a, self :: Paths a }
  deriving Functor

instance Alt VisPaths where
  VisPaths l1 s1 <!> VisPaths l2 s2 = VisPaths (l1 <!> l2) (s1 <!> s2)

instance Plus VisPaths where
  zero = VisPaths zero zero
    
introVis :: P.Vis Path Path -> Builder VisPaths
introVis (P.Priv p) = hoistBuilder (\ b -> zero {local = b}) (intro p)
introVis (P.Pub p) = hoistBuilder (\ b -> zero {self = b}) (intro p)

    
-- | A 'Pattern' is a value deconstructor and a group of paths to assign
data PattBuilder =
  PattB
    (Builder VisPaths)
    (forall k a . Ord k => E (Open (Tag k) a -> [Open (Tag k) a]))

-- | An ungroup pattern
data Ungroup =
  Ungroup
    PattBuilder
    -- ^ Builds the set of local and public assignments made by rhs patterns, where
    -- assigned values are obtained by deconstructing an original value
    [Ident]
    -- ^ List of fields of the original value used to obtain deconstructed values    
    
letpath :: P.Vis Path Path -> PattBuilder
letpath p = PattB (introVis p) (pure pure)

letungroup :: PattBuilder -> Ungroup -> PattBuilder
letungroup (PattB g1 v1) (Ungroup (PattB g2 v2) n) =
  PattB (g1 <> g2) (v1' <> v2)
    where
      -- left-hand pattern decomp function gets expression restricted to unused fields
      v1' :: forall k a . Ord k => E (Open (Tag k) a -> [Open (Tag k) a])
      v1' = (. rest) <$> v1
      
      rest :: Ord k => Open (Tag k) a -> Open (Tag k) a
      rest e = (Defn . hide (nub n) . selfApp . lift) (lift e)

      -- | Folds over a value to find keys to restrict for an expression.
      --
      -- Can be used as function to construct an expression of the 'left-over' components
      -- assigned to nested ungroup patterns.
      hide :: Foldable f => f Ident -> Closed (Tag k) a -> Closed (Tag k) a
      hide ks e = foldl (\ e k -> e `Fix` Key k) e ks
    
ungroup :: TupBuilder PattBuilder -> Ungroup
ungroup (TupB g ps) =
  Ungroup (PattB pg pf) (names g)
  where
    pf :: Ord k => E (Open (Tag k) a -> [Open (Tag k) a])
    pf = liftA2 applydecomp (ldecomp g) (snd pgfs)
  
    ldecomp :: Ord k => Builder Paths -> E (Open (Tag k) a -> [Open (Tag k) a])
    ldecomp g = (validatedecomp . unPaths . build g . repeat) (pure pure)
  
    applydecomp :: Monoid b => (a -> [a]) -> [a -> b] -> (a -> b)
    applydecomp s fs a = fold (zipWith ($) fs (s a))
    
    --pg :: Builder VisPaths
    pg = fst (pgfs :: (Builder VisPaths, E [Open (Tag ()) a -> [Open (Tag ()) a]]))
    pgfs :: Ord k => (Builder VisPaths, E [Open (Tag k) a -> [Open (Tag k) a]])
    pgfs = foldMap (\ (PattB g f) -> (g, pure <$> f)) ps
    
instance Semigroup PattBuilder where
  PattB g1 v1 <> PattB g2 v2 = PattB (g1 <> g2) (v1 <> v2)
  
instance Monoid PattBuilder where
  mempty = PattB mempty mempty
  mappend = (<>)
  
instance S.Self PattBuilder where self_ i = letpath (S.self_ i)
  
instance S.Local PattBuilder where local_ i = letpath (S.local_ i)
  
instance S.Field PattBuilder where
  type Compound PattBuilder = P.Vis Path Path
  v #. k = letpath (v S.#. k)

type instance S.Member PattBuilder = PattBuilder
type instance S.Member Ungroup = PattBuilder

instance S.Tuple PattBuilder where
  type Tup PattBuilder = TupBuilder PattBuilder
  tup_ g = p where Ungroup p _ = ungroup g
  
instance S.Tuple Ungroup where
  type Tup Ungroup = TupBuilder PattBuilder
  tup_ = ungroup
  
instance S.Extend PattBuilder where
  type Ext PattBuilder = Ungroup
  (#) = letungroup
    
-- | Build a recursive Block group
data BlockBuilder a = BlockB (Builder VisPaths) (E [a])

instance Semigroup (BlockBuilder a) where
  BlockB g1 v1 <> BlockB g2 v2 = BlockB (g1 <> g2) (v1 <> v2)
  
instance Monoid (BlockBuilder a) where
  mempty = BlockB mempty mempty
  mappend = (<>)
  
decl :: Path -> BlockBuilder a
decl (PathB f n) = BlockB g (pure [])
    where
      g = B_ {size=0, build=const (VisPaths p p), names=[n]}
      
      p :: forall a . Paths a
      p = Paths ((M.singleton n . f) (pure Nothing))
    
instance S.Self (BlockBuilder a) where
  self_ k = decl (S.self_ k)
  
instance S.Field (BlockBuilder a) where
  type Compound (BlockBuilder a) = Path
  b #. k = decl (b S.#. k)

instance Ord k => S.Let (BlockBuilder (Open (Tag k) a)) where
  type Lhs (BlockBuilder (Open (Tag k) a)) = PattBuilder
  type Rhs (BlockBuilder (Open (Tag k) a)) = E (Open (Tag k) a)
  PattB g f #= v = BlockB g (f <*> v)
      
instance S.Sep (BlockBuilder a) where
  BlockB g1 v1 #: BlockB g2 v2 = BlockB (g1 <> g2) (v1 <> v2)
  
instance S.Splus (BlockBuilder a) where
  empty_ = BlockB mempty mempty
    
    
-- | Validate a nested group of matched paths are disjoint, and extract
-- a decomposing function
validatedecomp
  :: (S.Path a, Monoid b)
  => M.Map Ident (An (Maybe (E (a -> b))))
     -- ^ Matched paths to nested patterns
  -> E (a -> b)
     -- ^ Value decomposition function
validatedecomp = fmap pattdecomp . M.traverseMaybeWithKey (go . Pure . P.K_) where
  go _ (An a Nothing) = sequenceA a
  go p (An a (Just b)) = (E . collect . pure) (OlappedMatch p)
    *> sequenceA a *> go p b
  go p (Un ma) = Just . pattdecomp 
    <$> M.traverseMaybeWithKey (go . Free . P.At p . P.K_) ma
    
  -- | Unfold a set of matched fields into a decomposing function
  pattdecomp :: (S.Path a, Monoid b) => M.Map Ident (a -> b) -> (a -> b)
  pattdecomp = M.foldMapWithKey (\ k f a -> f (a S.#. k))

  
-- | Tree of paths with one or values contained in leaves and zero or more
--   in internal nodes
--
--   Semigroup and monoid instances defined will union subtrees recursively
--   and accumulate values.
data An a = An a (Maybe (An a)) | Un (M.Map Ident (An a))
  deriving (Functor, Foldable, Traversable)
  
instance Applicative An where
  pure a = An a Nothing
  (<*>) = ap
  
instance Monad An where
  return = pure
  
  An a Nothing >>= k = k a
  An a (Just as) >>= k = k a <!> (as >>= k)
  Un ma >>= k = Un ((>>= k) <$> ma)
  
instance MonadFree (M.Map Ident) An where
  wrap = Un
  
instance Alt An where
  An x (Just a) <!> b = (An x . Just) (a <!> b)
  An x Nothing <!> b = An x (Just b)
  a <!> An x Nothing = An x (Just a)
  a <!> An x (Just b) = (An x . Just) (a <!> b)
  Un ma <!> Un mb = Un (M.unionWith (<!>) ma mb)

