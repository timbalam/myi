{-# LANGUAGE RankNTypes, TypeFamilies, FlexibleContexts, FlexibleInstances, LambdaCase, DeriveFunctor #-}
module Goat.Repr.Lang.Expr
  ( module Goat.Repr.Lang.Expr
  , Self
  ) where

import Goat.Lang.Class
import Goat.Lang.Parser
  ( Self(..), notSelf
  , IDENTIFIER, parseIdentifier
  , BLOCK, parseBlock
  , STMT, parseStmt
  , DEFINITION, parseDefinition
  , PATTERN, parsePattern
  , PATH, parsePath
  )
import Goat.Repr.Pattern
import Goat.Repr.Lang.Pattern
import Goat.Repr.Expr
import Goat.Util ((<&>), (...))
import Data.Bifunctor (first)
import Data.Bitraversable (bitraverse)
import Data.Coerce (coerce)
import Data.Function (on)
import Data.Monoid (Endo(..))
import qualified Data.Text as Text
import Bound ((>>>=))

-- Block

newtype ReadBlock a =
  ReadBlock {
    readBlock
     :: Bind
          Declares
          (Multi Identity)
          (Repr () (Multi Identity))
          a
    }

proofBlock
 :: BLOCK a -> ReadBlock (Either (Esc ReadExpr) a)
proofBlock = parseBlock id

instance IsList (ReadBlock a) where
  type Item (ReadBlock a) = ReadStmt a
  fromList bdy = ReadBlock (foldMap readStmt bdy)
  toList =
    error
      "IsList (ReadPunBlock (Either Self ReadExpr) a): toList"

{- 
Stmt
----

We represent a *statement* as a set of declared bindings of values.
A *pun statement* generates an _escaped_ path and a corresponding binding selector.
-}

data Esc a = Escape a | Contain a deriving Functor

newtype ReadStmt a =
  ReadStmt {
    readStmt
     :: Bind
          Declares
          (Multi Identity)
          (Repr () (Multi Identity))
          a
    }

proofStmt :: STMT a -> ReadStmt (Either (Esc ReadExpr) a)
proofStmt = parseStmt id

data ReadPun = ReadPun (forall a . Selector_ a => a) ReadPathPun

proofPun :: PATH -> ReadPun
proofPun = parsePath

punStmt :: Selector_ a => ReadPun -> ReadStmt (Either (Esc a) b)
punStmt (ReadPun a p) = case pathPunStmt p of
  ReadPatternPun (ReadStmt bs) (ReadPattern f) ->
    ReadStmt (f (Left (Escape a)) `mappend` bs)

instance IsString ReadPun where
  fromString s =
    ReadPun (fromString "" #. fromString s) (fromString s)

instance IsString a => IsString (Esc a) where
  fromString s = Contain (fromString s)

instance
  Selector_ a => IsString (ReadStmt (Either (Esc a) b))
  where
    fromString s = punStmt (fromString s)

instance Select_ ReadPun where
  type Selects ReadPun = Either Self ReadPun
  type Key ReadPun = IDENTIFIER
  Left Self #. k =
    ReadPun (fromString "" #. parseIdentifier k) (Left Self #. k)
  Right (ReadPun a b) #. k =
    ReadPun (a #. parseIdentifier k) (Right b #. k)

instance Select_ a => Select_ (Esc a) where
  type Selects (Esc a) = Selects a
  type Key (Esc a) = Key a
  a #. k = Contain (a #. k)

instance
  Selector_ a => Select_ (ReadStmt (Either (Esc a) b))
  where
    type Selects (ReadStmt (Either (Esc a) b)) =
      Either Self ReadPun
    type Key (ReadStmt (Either (Esc a) b)) = IDENTIFIER
    r #. k = punStmt (r #. k)

instance Selector_ a => Assign_ (ReadStmt (Either a b)) where
  type Lhs (ReadStmt (Either a b)) = ReadPatternPun a b
  type Rhs (ReadStmt (Either a b)) = b
  ReadPatternPun (ReadStmt bs) (ReadPattern f) #= b =
    ReadStmt (f (Right b) `mappend` bs)


-- Generate a local pun for each bound public path.

data ReadPathPun =
  ReadPublic (forall a . Selector_ a => a) ReadPath ReadPath |
  ReadLocal ReadPath

proofPath :: PATH -> ReadPathPun
proofPath = parsePath

data ReadPatternPun a b =
  ReadPatternPun (ReadStmt (Either a b)) ReadPattern

proofPattern :: Selector_ a => PATTERN -> ReadPatternPun a b
proofPattern = parsePattern

pathPunStmt :: Selector_ a => ReadPathPun -> ReadPatternPun a b
pathPunStmt (ReadLocal p) =
  ReadPatternPun (ReadStmt mempty) (setPattern p)
pathPunStmt (ReadPublic a lp pp) =
  ReadPatternPun
    (ReadStmt
      (readPattern (setPattern lp) (Left a)))
    (setPattern pp)

instance IsString ReadPathPun where
  fromString s = ReadLocal (fromString s) 

instance IsString (ReadPatternPun a b) where
  fromString s = ReadPatternPun (ReadStmt mempty) (fromString s)

instance Select_ ReadPathPun where
  type Selects ReadPathPun = Either Self ReadPathPun
  type Key ReadPathPun = IDENTIFIER
  Left Self #. k =
    ReadPublic
      (fromString "" #. parseIdentifier k)
      (parseIdentifier k)
      (Left Self #. k)
  
  Right (ReadLocal p) #. k = ReadLocal (Right p #. k)
  Right (ReadPublic a l p) #. k =
    ReadPublic
      (a #. parseIdentifier k)
      (Right l #. k)
      (Right p #. k)

instance Selector_ a => Select_ (ReadPatternPun a b) where
  type Selects (ReadPatternPun a b) = Either Self ReadPathPun
  type Key (ReadPatternPun a b) = IDENTIFIER
  p #. k = pathPunStmt (p #. k)


instance Selector_ a => IsList (ReadPatternPun a b) where
  type Item (ReadPatternPun a b) =
    ReadMatchStmt
      (Either (ReadPatternPun a b) (ReadPatternPun a b))
  fromList ms =
    ReadPatternPun (ReadStmt bs) (fromList ms')
    where
      (bs, ms') =
        traverse
          (\ (ReadMatchStmt m) ->
            ReadMatchStmt <$>
              traverse (bitraverse punToPair punToPair) m)
          ms
      
      punToPair (ReadPatternPun (ReadStmt bs) p) = (bs, p)
  
  toList = error "IsList (ReadPatternPun a): toList"

instance Selector_ a => Extend_ (ReadPatternPun a b) where
  type Extension (ReadPatternPun a b) =
    ReadPatternBlock
      (Either (ReadPatternPun a b) (ReadPatternPun a b))
  ReadPatternPun (ReadStmt bs) p # ReadPatternBlock m =
    ReadPatternPun
      (ReadStmt (bs' `mappend` bs))
      (p # ReadPatternBlock m')
    where
      (bs', m') = traverse (bitraverse punToPair punToPair) m
      
      punToPair (ReadPatternPun (ReadStmt bs) p) = (bs, p)

{-
Definition
----------

We represent an _escaped_ definiton as a definition nested inside a variable.
-}

newtype ReadExpr =
  ReadExpr {
    readExpr
     :: Repr () (Multi Identity)
          (VarName Ident Ident (Import Ident))
    }

proofDefinition :: DEFINITION -> Either Self ReadExpr
proofDefinition = parseDefinition

getDefinition
 :: Either Self ReadExpr
 -> Repr () (Multi Identity) (VarName Ident Ident (Import Ident))
getDefinition m = readExpr (notSelf m)

definition
 :: Repr () (Multi Identity) (VarName Ident Ident (Import Ident))
 -> Either Self ReadExpr
definition m = pure (ReadExpr m)

escapeExpr
 :: Monad m
 => Esc (m (VarName a b c))
 -> m (VarName a b (m (VarName a b c)))
escapeExpr (Escape m) = return (Right (Right m))
escapeExpr (Contain m) =
  m <&> fmap (fmap (return . Right . Right))

joinExpr
 :: Monad m
 => m (VarName a b (m (VarName a b c)))
 -> m (VarName a b c)
joinExpr m = m >>= \case
  Left l -> return (Left l)
  Right (Left p) -> return (Right (Left p))
  Right (Right m) -> m

newtype ReadValue = ReadValue { readValue :: forall a . Value a }

fromValue :: ReadValue -> Either Self ReadExpr
fromValue (ReadValue v) = pure (ReadExpr (repr (Value v)))

instance Num ReadValue where
  fromInteger d = ReadValue (Number (fromInteger d))
  (+) = error "Num ReadValue: (+)"
  (*) = error "Num ReadValue: (*)"
  abs = error "Num ReadValue: abs"
  signum = error "Num ReadValue: signum"
  negate = error "Num ReadValue: negate"

instance Num (Either Self ReadExpr) where
  fromInteger d = fromValue (fromInteger d)
  (+) = error "Num (Either Self ReadExpr): (+)"
  (*) = error "Num (Either Self ReadExpr): (*)"
  abs = error "Num (Either Self ReadExpr): abs"
  signum = error "Num (Either Self ReadExpr): signum"
  negate = error "Num (Either Self ReadExpr): negate"

instance Fractional ReadValue where
  fromRational r = ReadValue (Number (fromRational r))
  (/) = error "Fractional ReadValue: (/)"
  
instance Fractional (Either Self ReadExpr) where
  fromRational r =  fromValue (fromRational r)
  (/) = error "Fractional (Either Self ReadExpr): (/)"

instance TextLiteral_ ReadValue where
  quote_ s = ReadValue (Text (Text.pack s))
  
instance TextLiteral_ (Either Self ReadExpr) where
  quote_ s = fromValue (quote_ s)

readBinop
 :: (forall f m x . m x -> m x -> Expr f m x)
 -> Either Self ReadExpr
 -> Either Self ReadExpr
 -> Either Self ReadExpr
readBinop op m n = definition (repr (on op getDefinition m n))

readUnop
 :: (forall f m x . m x -> Expr f m x)
 -> Either Self ReadExpr -> Either Self ReadExpr
readUnop op m = definition (repr (op (getDefinition m)))

instance Operator_ (Either Self ReadExpr) where
  (#+)  = readBinop Add
  (#-)  = readBinop Sub
  (#*)  = readBinop Mul
  (#/)  = readBinop Div
  (#^)  = readBinop Pow
  (#==) = readBinop Eq
  (#!=) = readBinop Ne
  (#<)  = readBinop Lt
  (#<=) = readBinop Le
  (#>)  = readBinop Gt
  (#>=) = readBinop Ge
  (#||) = readBinop Or
  (#&&) = readBinop And
  neg_  = readUnop Neg
  not_  = readUnop Not
  
instance Use_ (Either Self ReadExpr) where
  type Extern (Either Self ReadExpr) = IDENTIFIER
  use_ k =
    definition
      (Var (Right (Right (Import (parseIdentifier k)))))

instance IsString ReadExpr where
  fromString s =
    ReadExpr (Var (Right (Left (Local (fromString s)))))

instance Select_ ReadExpr where
  type Selects ReadExpr = Either Self ReadExpr
  type Key ReadExpr = IDENTIFIER
  Left Self #. k =
    ReadExpr (Var (Left (Public (parseIdentifier k))))
  Right (ReadExpr m) #. k =
    ReadExpr (repr (Sel m (parseIdentifier k)))

instance IsList (Either Self ReadExpr) where
  type Item (Either Self ReadExpr) =
    ReadStmt (Either (Esc ReadExpr) (Either Self ReadExpr))
  fromList bdy =
    definition 
      (joinExpr (wrapBlock (absFromBindings bs emptyRepr)))
    where
      bs =
        readBlock (fromList bdy) >>>=
          escapeExpr .
          either
            (fmap readExpr)
            (Contain . getDefinition)

  toList = error "IsList (Either Self ReadExpr): toList"

instance Extend_ (Either Self ReadExpr) where
  type Extension (Either Self ReadExpr) =
    ReadBlock (Either (Esc ReadExpr) (Either Self ReadExpr))
  a # ReadBlock bs =
    definition (joinExpr (wrapBlock (absFromBindings bs' a')))
    where
      bs' = 
        bs >>>=
          escapeExpr .
          either
            (fmap readExpr)
            (Contain . getDefinition)
      a' = escapeExpr (Escape (getDefinition a))
