--{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ExistentialQuantification, GeneralizedNewtypeDeriving, DeriveFunctor, DeriveFoldable, DeriveTraversable, StandaloneDeriving, RankNTypes, FlexibleInstances, FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies, MultiParamTypeClasses #-}
module Goat.Repr.Pattern
  where

import Goat.Repr.Assoc
import Goat.Lang.Ident (Ident)
import Goat.Util (swap, assoc, reassoc)
import Bound
import Bound.Scope
import Control.Applicative (liftA2, Alternative(..))
import Control.Monad.Trans (lift)
import Control.Monad.Cont (cont, runCont)
import Data.These
import Data.Align
import Data.Traversable (mapAccumL)
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
import Data.Biapplicative
import Data.Coerce (coerce)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map as Map 
import qualified Data.Text as Text
import Data.Maybe (fromMaybe)
import Data.Semigroup
import qualified Data.Monoid as Monoid (Alt(..))
import Data.Void (Void, absurd)
import Data.Functor.Identity (Identity(..))
import Data.Functor.Plus (Alt(..), Plus(..))

{-
Pattern
----

The interpretation of pattern syntax is defined in
'Goat.Repr.Lang.Pattern'.
-}


-- |
bindMatchSelection
 :: (Plus f, MonadBlock (Abs FieldSelection) m)
 => MatchSelection
      (m (Local Int) ->
        Bindings f (FieldSelection ()) m (Local Int))
 -> (forall x. m x -> Bindings f (FieldSelection ()) m x)
 -> m b
 -> Bindings f (FieldSelection ()) m b
bindMatchSelection (MatchSelection r k) f b =
  embedBindings
    (\ (Parts fm (Identity m)) ->
      Define (return <$> fm) <!> f (return m))
    (bindFieldSelectionToParts pg (lift b) xm)
  where
    (pg, xm) =
      matchingsParts r (fmap (patternAssigns patternLeaf . k))
  
    patternLeaf
     :: (Foldable t, Alternative f, Plus g, Monad m)
     => t (m (Local Int) -> Bindings g p m (Local Int))
     -> (f (), Int ->
          Bindings (Parts g Maybe) p (Scope (Local Int) m) a)
    patternLeaf t = (f, matchings)
      where
        (Monoid.Alt f, k) = foldMap pure t
        
        matchings i =
          transBindings
            (\ g -> Parts g Nothing)
            (hoistBindings
              lift
              (k (return (Local i)))
              >>>= Scope . return . B)

type Matchings f m a =
  Int -> Bindings f (FieldSelection ()) (Scope (Local Int) m) a

patternAssigns
 :: (Plus f, MonadBlock (Abs (Pattern s)) m, Monoid s)
 => (a -> ([()], Matchings (Parts f Maybe) s m b))
 -> Assigns Assoc a
 -> ([()], Matchings (Parts f Maybe) s m b)
patternAssigns k =
  mergeMatchings .
    iterAssigns
      k
      (\ r k i ->
        let (pg, xm) = matchingsParts r (pure . mergeMatchings . k)
        in 
          hoistBindings lift
            (patternParts
              pg
              (return (B (Local i)))
              (F . return <$> xm))
            >>>= Scope . return)
  where
    mergeMatchings
     :: (Monoid m, Alternative f)
     => These (f (), m) m -> (f (), m)
    mergeMatchings (This p) = p
    mergeMatchings (That m) = (pure (), m)
    mergeMatchings (These (f, m) m') =
      (f <|> pure (), m `mappend` m')


bindFieldSelectionToParts
 :: (Functor f, MonadBlock (Abs FieldSelection) m, Applicative h)
 => FieldSelection ()
 -> Scope (Local Int) m a
 -> Bindings
      (Parts f FieldSelection)
      (FieldSelection ())
      (Scope (Local Int) m)
      a
 -> Bindings (Parts f h) (FieldSelection ()) m a
bindFieldSelectionToParts pg a xm =
  embedBindings
    (Define . wrapRemaining)
    (Let pg a xm)
  where
    wrapRemaining
     :: ( Functor f, Functor r, MonadBlock (Abs r) m
        , Applicative h)
     => Parts f r a -> Parts f h (m a)
    wrapRemaining (Parts f x) =
      Parts
        (return <$> f)
        (pure (wrapBlock (Abs (Define (return <$> x)))))


matchingsParts
 :: (Plus f, Monad m, Monoid s)
 => Map Text a
 -> (a -> ([()], Matchings (Parts f Maybe) m b))
 -> ( FieldSelection ()
    , Bindings
        (Parts f FieldSelection)
        (FieldSelection ())
        (Scope (Local Int) m)
        b
    )
matchingsParts r k = (pg, foldParts xm)
  where
    x = Extend
          (Reveal (k <$> r))
          ([], remaining)
    pg = MatchSelection (fst <$> x)
    xm = mapWithIndex (\ i (_, f) -> f i) x
    
    remaining i =
      Define
        (Parts zero
          (Just (Scope (return (B (Local i))))))
      
foldParts
 :: (Plus f, Monad m, Monoid s)
 => Extend (Map Text s) (Bindings (Parts f Maybe) p m a)
 -> Bindings (Parts f FieldSelection) p m a
foldParts (Extend r m) =
  liftBindings2
    (mergeParts .
      hoistParts (transStores (first unwrapMonoid)))
    (foldMapWithKey (\ n -> hoistField n . first WrapMonoid) rm)
    (hoistRemaining m)
  where
    mergeParts
     :: (Alt f, Applicative g, Functor r)
     => Parts f (Stores g r) a
     -> Parts f g a
     -> Parts f (Stores g (Extend r)) a
    mergeParts (Parts f1 (Stores rg)) (Parts f2 g) =
      Parts (f1 <!> f2) (Stores (Extend rg g))
    
    hoistField
     :: (Monoid s, Semigroup s)
     => Ident
     -> Views s (Bindings (Parts f Maybe) p m a)
     -> Bindings (Parts f (Many (Reveal Assoc s))) p m a
    hoistField n (Views s m) =
      transBindings
        (hoistParts
          (maybe
            mempty
            (Stores .
              Reveal .
              singleton n .
              bipure s .
              pure)))
        m
  
    hoistRemaining
     :: Alternative g
     => Bindings (Parts f Maybe) p m a
     -> Bindings (Parts f g) p m a
    hoistRemaining =
      transBindings
        (hoistParts (maybe empty pure))


mapWithIndex
 :: Traversable t
 => (Int -> a -> b) -> t a -> t b
mapWithIndex f t =
  snd (mapAccumL (\ i a -> (i+1, f i a)) 0 t)  
  

type FieldSelection = Many (Extend (Map Text))


-- |
data Extend r a = Extend (r a) a
  deriving (Functor, Foldable, Traversable)

hoistExtend
 :: (forall x . q x -> r x) -> Extend q a -> Extend r a
hoistExtend f (Extend r a) = Extend (f r) a

instance (Monoid (r a), Monoid a) => Monoid (Extend r a) where
  mempty = Extend mempty mempty
  Extend r1 a1 `mappend` Extend r2 a2 =
    Extend (r1 `mappend` r2) (a1 `mappend` a2)



-- | 'Bindings f p m a' binds expressions of type 'm a'
-- inside a container 'f' to patterns of type 'p'. 
data Bindings f p m a =
    Define (f (m a))
  | Let
      p
      (Scope (Local Int) m a)
      (Bindings f p (Scope (Local Int) m) a)
  deriving (Functor, Foldable, Traversable)

-- | Higher order map over expression type.
hoistBindings
 :: (Functor f, Functor m)
 => (forall x . m x -> n x)
 -> Bindings f p m a -> Bindings f p n a
hoistBindings f (Define fm) = Define (f <$> fm)
hoistBindings f (Let p m t) =
  Let p (hoistScope f m) (hoistBindings (hoistScope f) t)

-- | Higher order map over container type.
transBindings
 :: (forall x . f x -> g x)
 -> Bindings f p m a -> Bindings g p m a
transBindings f (Define fm) = Define (f fm)
transBindings f (Let p m t) = Let p m (transBindings f t)

-- | Higher order traverse over container type.
transverseBindings
 :: Functor h
 => (forall x . f x -> h (g x))
 -> Bindings f p m a -> h (Bindings g p m a)
transverseBindings f (Define fm) = Define <$> f fm
transverseBindings f (Let p m t) =
  Let p m <$> transverseBindings f t

-- | Higher order applicative function lifting over container type.
liftBindings2
 :: (Functor f, Functor g, Monad m)
 => (forall x . f x -> g x -> h x)
 -> Bindings f p m a -> Bindings g p m a -> Bindings h p m a
liftBindings2 f (Define fm) (Define gm) = Define (f fm gm)
liftBindings2 f (Let p m tf) (Define gm) =
  Let p m (liftBindings2 f tf (hoistBindings lift (Define gm)))
liftBindings2 f tf (Let p m tg) =
  Let p m (liftBindings2 f (hoistBindings lift tf) tg)

-- | Higher order bind over container type.
embedBindings
 :: (Functor g, Monad m)
 => (forall x . f x -> Bindings g p m x)
 -> Bindings f p m a -> Bindings g p m a
embedBindings f (Define fm) = f fm >>>= id
embedBindings f (Let p m t) =
  Let p m (embedBindings (hoistBindings lift . f) t)

-- | Higher order join over container type
squashBindings
 :: (Functor f, Monad m)
 => Bindings (Bindings f p m) p m a -> Bindings f p m a
squashBindings = embedBindings id

instance Functor f => Bound (Bindings f p) where
  Define fm     >>>= f = Define ((>>= f) <$> fm)
  Let p m t >>>= f = Let p (m >>>= f) (t >>>= lift . f)

instance (Alt f, Monad m) => Alt (Bindings f p m) where
  a <!> b = liftBindings2 (<!>) a b 

instance (Plus f, Monad m) => Plus (Bindings f p m) where
  zero = Define zero

instance (Plus f, Monad m) => Monoid (Bindings f p m a) where
  mempty = zero
  mappend a b = a <!> b
  

-- | Match data to selected parts of a value
data MatchSelection a =
  forall x .
    MatchSelection
      (Map Text x)
      (x -> Assigns (Map Text) (NonEmpty a))

sendMatchSelection
 :: Map Text a -> MatchSelection a
sendMatchSelection r = MatchSelection r (Leaf . pure)

wrapMatchSelection
 :: Map Text (Assigns (Map Text) a) -> MatchSelection a
wrapMatchSelection r = MatchSelection r (fmap pure)

instance Functor MatchSelection where
  fmap f (MatchSelection r k) =
    MatchSelection r (fmap (fmap f) . k)

instance Foldable MatchSelection where
  foldMap f (MatchSelection r k) =
    foldMap (foldMap (foldMap f) . k) r

instance Traversable MatchSelection where
  traverse f (MatchSelection r k) =
    MatchSelection <$> 
      traverse (traverse (traverse f) . k) r <*>
      pure id
      
instance Alt MatchSelection where
  MatchSelection ra ka <!> MatchSelection rb kb =
    MatchSelection
      (align ra rb)
      (these id id (<!>) <$> bicrosswalkAssigns ka kb)

instance Plus MatchSelection where
  zero = MatchSelection nil id
  
instance Monoid (MatchSelection a) where
  mempty = zero
  mappend = (<!>)


-- | Associate a set of fields with values, possibly ambiguously
data Assigns r a =
    forall x . Node (r x) (x -> Assigns r a)
  | Leaf a
  | forall x . Overlap (r x) (x -> Assigns r a) a

sendAssigns :: r a -> Assigns r a
sendAssigns r = Node r Leaf

wrapAssigns :: r (Assigns r a) -> Assigns r a
wrapAssigns r = Node r id

alignAssignsWith
 :: Align r
 => (These a b -> c)
 -> Assigns r a -> Assigns r b -> Assigns r c
alignAssignsWith = alignpw where
    alignnw
     :: Align r 
     => (These a b -> c)
     -> r x -> (x -> Assigns r a)
     -> r y -> (y -> Assigns r b)
     -> (forall xx . r xx -> (xx -> Assigns r c) -> p)
     -> p
    alignnw f ra ka rb kb g =
      g (align ra rb) (fmap f . bicrosswalkAssigns ka kb)
    
    alignpw
     :: Align r
     => (These a b -> c)
     -> Assigns r a -> Assigns r b -> Assigns r c
    alignpw f (Node ra ka) (Node rb kb) =
      alignnw f ra ka rb kb Node
    alignpw f (Node ra ka) (Leaf b) =
      Overlap ra (fmap (f . This) . ka) (f (That b))
    alignpw f (Node ra ka) (Overlap rb kb b) =
      alignnw f ra ka rb kb Overlap (f (That b))
    alignpw f (Leaf a) (Node rb kb) =
      Overlap rb (fmap (f . That) . kb) (f (This a))
    alignpw f (Leaf a) (Leaf b) =
      Leaf (f (These a b))
    alignpw f (Leaf a) (Overlap rb kb b) =
      Overlap rb (fmap (f . That) . kb) (f (These a b))
    alignpw f (Overlap ra ka a) (Node rb kb)   =
      alignnw f ra ka rb kb Overlap (f (This a))
    alignpw f (Overlap ra ka a) (Leaf b) =
      Overlap ra (fmap (f . This) . ka) (f (These a b))
    alignpw f (Overlap ra ka a) (Overlap rb kb b) =
      alignnw f ra ka rb kb Overlap (f (These a b))

bicrosswalkAssigns
 :: Align r 
 => (a -> Assigns r c)
 -> (b -> Assigns r d)
 -> These a b
 -> Assigns r (These c d)
bicrosswalkAssigns f g (This a) = This <$> f a
bicrosswalkAssigns f g (That b) = That <$> g b
bicrosswalkAssigns f g (These a b) =
  alignAssignsWith id (f a) (g b)

iterAssigns
 :: (a -> b)
 -> (forall x . r x -> (x -> These b c) -> c)
 -> Assigns r a
 -> These b c
iterAssigns = iterAssigns' where
  iterAssigns'
   :: (a -> b)
   -> (forall x . r x -> (x -> These b c) -> c)
   -> Assigns r a
   -> These b c
  iterAssigns' ka kf (Leaf a) = This (ka a)
  iterAssigns' ka kf (Node r k) = That (iterNode ka kf r k)
  iterAssigns' ka kf (Overlap r k a) =
    These (ka a) (iterNode ka kf r k)
  
  iterNode
   :: (a -> b)
   -> (forall x . r x -> (x -> These b c) -> c)
   -> r y
   -> (y -> Assigns r a)
   -> c
  iterNode ka kf r k = kf r (iterAssigns ka kf . k)

instance Functor (Assigns r) where
  fmap f (Node r k) = Node r (fmap f . k)
  fmap f (Leaf a) = Leaf (f a)
  fmap f (Overlap r k a) = Overlap r (fmap f . k) (f a)

instance Foldable r => Foldable (Assigns r) where
  foldMap f (Node r k) = foldMap (foldMap f . k) r
  foldMap f (Leaf a) =  f a
  foldMap f (Overlap r k a) =
    foldMap (foldMap f . k) r `mappend` f a

instance Traversable r => Traversable (Assigns r) where
  traverse f = traverse' f where
    traverseNode
      :: (Traversable r, Applicative f)
      => (a -> f b)
      -> r x -> (x -> Assigns r a)
      -> (forall xx . r xx -> (xx -> Assigns r b) -> p)
      -> f p
    traverseNode f r k g =
      g <$> traverse (traverse f . k) r <*> pure id
    
    traverse' f (Node r k) =
      traverseNode f r k Node
    traverse' f (Leaf a) = Leaf <$> f a
    traverse' f (Overlap r k a) =
      traverseNode f r k Overlap <*> f a
  
-- | Access controlled labels
newtype Public a = Public { getPublic :: a }
  deriving (Functor, Foldable, Traversable, Semigroup, Monoid)
newtype Local a = Local { getLocal :: a }
  deriving (Functor, Foldable, Traversable, Semigroup, Monoid)
newtype Match a = Match { getMatch :: a }
  deriving (Functor, Foldable, Traversable, Semigroup, Monoid)

type Privacy p = p (Public ()) (Local ())

data Views s a = Views s a
  deriving (Functor, Foldable, Traversable)

instance Monoid s => Applicative (Views s) where
  pure a = Views mempty a
  Views s1 f <*> Views s2 a = Views (s1 `mappend` s2) (f a)

instance (Monoid s, Monoid a) => Monoid (Views s a) where
  mempty = Views mempty mempty
  Views s1 a1 `mappend` Views s2 a2 =
    Views (s1 `mappend` s2) (a1 `mappend` a2)

instance Bifunctor Views where
  bimap f g (Views s a) = Views (f s) (g a)

instance Biapplicative Views where
  bipure s a = Views s a
  Views f g <<*>> Views s a = Views (f s) (g a)
  
instance Bifoldable Views where
  bifoldMap f g (Views s a) = f s `mappend` g a
    
instance Bitraversable Views where
  bitraverse f g (Views s a) = Views <$> f s <*> g a

bicrosswalkViews
 :: Semigroup s
 => (a -> Views s c)
 -> (b -> Views s d)
 -> These a b
 -> Views s (These c d)
bicrosswalkViews f g (This a) = This <$> f a
bicrosswalkViews f g (That b) = That <$> g b
bicrosswalkViews f g (These a b) =
  bimap (<>) These (f a) <<*>> g b

newtype Reveal r s a = Reveal (r (Views s a))
  deriving (Functor, Foldable, Traversable)

hoistReveal
 :: (forall x . q x -> r x)
 -> Reveal q s a -> Reveal r s a
hoistReveal f (Reveal r) = Reveal (f r)

instance Functor r => Bifunctor (Reveal r) where
  bimap f g (Reveal r) = Reveal (bimap f g <$> r)

instance Foldable r => Bifoldable (Reveal r) where
  bifoldMap f g (Reveal r) = foldMap (bifoldMap f g) r

instance Traversable r => Bitraversable (Reveal r) where
  bitraverse f g (Reveal r) =
    Reveal <$> traverse (bitraverse f g) r

instance (Align r, Semigroup s) => Align (Reveal r s) where
  nil = Reveal nil
  
  align (Reveal ra) (Reveal rb) =
    Reveal (alignWith (bicrosswalkViews id id) ra rb)


-- |
newtype Stores f r a = Stores { getStores :: r (f a) }
  deriving (Functor, Foldable, Traversable)

hoistStores
 :: Functor r
 => (forall x. f x -> g x)
 -> Stores f r a -> Stores g r a
hoistStores f (Stores r) = Stores (f <$> r)

transStores
 :: (forall x. q x -> r x)
 -> Stores f q a -> Stores f r a
transStores f (Stores r) = Stores (f r)
  
instance (Alt f, Align r) => Alt (Stores f r) where
  Stores a <!> Stores b =
    Stores (alignWith (these id id (<!>)) a b)

instance (Alt f, Align r) => Plus (Stores f r) where
  zero = Stores nil
  
instance (Alt f, Align r) => Monoid (Stores f r a) where
  mempty = zero
  mappend = (<!>)

type Multi = Stores NonEmpty
type Many = Stores []

-- |
data Parts f g a = Parts (f a) (g a) deriving Functor

hoistParts
 :: (forall x . g x -> h x)
 -> Parts f g a -> Parts f h a
hoistParts f (Parts fa ga) = Parts fa (f ga)

instance (Align f, Align g) => Align (Parts f g) where
  nil = Parts nil nil
  alignWith f (Parts fa ga) (Parts fb gb) =
    Parts (alignWith f fa fb) (alignWith f ga gb)

instance (Alt f, Alt g) => Alt (Parts f g) where
  Parts fa ga <!> Parts fb gb = Parts (fa <!> fb) (ga <!> gb)

instance (Plus f, Plus g) => Plus (Parts f g) where
  zero = Parts zero zero

instance (Monoid (f a), Monoid (g a)) => Monoid (Parts f g a) where
  mempty = Parts mempty mempty
  Parts fa ga `mappend` Parts fb gb =
    Parts (fa `mappend` fb) (ga `mappend` gb)

-- |
type Block r m a = Bindings r (r ()) m a

newtype Abs r m a = Abs (Block r (Scope (Public Ident) m) a)
  deriving (Functor, Foldable, Traversable)

hoistAbs
 :: (Functor r, Functor m)
 => (forall x . m x -> n x)
 -> Abs r m a -> Abs r n a
hoistAbs f (Abs b) = Abs (hoistBindings (hoistScope f) b)

instance Functor r => Bound (Abs r) where
  Abs b >>>= f = Abs (b >>>= lift . f)

-- | Wrap nested expressions
class Monad m => MonadBlock r m | m -> r where
  wrapBlock :: r m a -> m a
