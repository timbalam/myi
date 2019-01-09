{-# LANGUAGE FlexibleInstances, UndecidableInstances, FlexibleContexts, ScopedTypeVariables, RankNTypes, DeriveFunctor, GeneralizedNewtypeDeriving #-}

module Goat.Syntax.Binop
  where
  
import Goat.Syntax.Symbol
import Goat.Syntax.Fixity
import qualified Text.Parsec as Parsec
import Text.Parsec ((<|>))
import Text.Parsec.Text (Parser)
import Data.Bifunctor
import Control.Monad.Free.Church
  
infixr 8 #^, :#^
infixl 7 #*, #/, :#*, :#/
infixl 6 #+, #-, :#+, :#-
infix 4 #==, #!=, #<, #<=, #>, #>=, :#==, :#!=, :#<, :#<=, :#>, :#>=
infixr 3 #&&, :#&&
infixr 2 #||, :#||

data AddOp a b =
    b :#+ a
  | b :#- a
    -- ^ left associative
  deriving (Eq, Show)
  
showAddOp :: (a -> ShowS) -> (b -> ShowS) -> AddOp a b -> ShowS
showAddOp f g (b :#+ a) = showInfix g f Add b a
showAddOp f g (b :#- a) = showInfix g f Sub b a

instance Bifunctor AddOp where
  bimap f g (b :#+ a) = g b :#+ f a
  bimap f g (b :#- a) = g b :#- f a
  
data MulOp a b =
    b :#* a
  | b :#/ a
    -- ^ left associative
  deriving (Eq, Show)
  
showMulOp :: (a -> ShowS) -> (b -> ShowS) -> MulOp a b -> ShowS
showMulOp f g (b :#* a) = showInfix g f Mul b a
showMulOp f g (b :#/ a) = showInfix g f Div b a

instance Bifunctor MulOp where
  bimap f g (b :#* a) = g b :#* f a
  bimap f g (b :#/ a) = g b :#/ f a
  
data PowOp a b =
  a :#^ b
  -- ^ right-associative
  deriving (Eq, Show) 
  
showPowOp :: (a -> ShowS) -> (b -> ShowS) -> PowOp a b -> ShowS
showPowOp f g (a :#^ b) = showInfix f g Pow a b

instance Bifunctor PowOp where
  bimap f g (a :#^ b) = f a :#^ g b

showInfix
  :: (a -> ShowS) -> (b -> ShowS) -> Symbol -> a -> b -> ShowS
showInfix showa showb op a b =
  showa a
    . showChar ' '
    . showSymbol op
    . showChar ' '
    . showb b


type ArithB = FreeT (InfixA PowOp) MulB
-- MulB (a)
--   | MulB (ArithB a ^ ArithB a ^ ArithB a ...)
newtype MulB a = MulB (FreeT (InfixA MulOp a) AddB a)
-- AddB a
--   | AddB (a * MulB)
--   | AddB (a * MulB * MulB)
--   | AddB (a * ...)
newtype AddB a = AddB (Free (InfixA AddOp a) a)
-- a
--   | a + AddB a
--   | a + AddB a + AddB a
--   | a + ...


arithMul
  :: FreeF (InfixA MulOp) a (MulB a) -> MulB a
arithMul (Pure a)

arithAdd
 :: ArithB a
 -> Op (InfixA AddOp) (AddB (FreeF (InfixA MulOp) a (MulB a)))
arithAdd (FreeT (FreeT m)) = case runFree m of
  Pure mulf -> Term (Pure mulf)
    -- FreeF mul
    --   (FreeF pow a (ArithB a))
    --   (FreeT mul (Free pl) (FreeF pow a (ArithB a)))
  Free a -> Op (fmap runFreeT a)
    -- pl (FreeT mul (Free pl) (FreeF pow a (ArithB a)))
  -- ArithB a = FreeT pow (FreeT mul (Free pl)) a
  -- runFreeT (ArithB a)
  --   = FreeT
  --      mul
  --      (Free pl)
  --      (FreeF pow a (ArithB a))
  -- runFreeT (runFreeT (ArithB a))
  --   = Free
  --       pl
  --       (FreeF
  --         mul
  --         (FreeF
  --           pow
  --           a
  --           (ArithB a))
  --         (FreeT
  --           mul
  --           (Free pl)
  --           (FreeF pow a (ArithB a)))))

arithMul
 :: MonadFree (Op (InfixA AddOp)) (Op (InfixA MulOp))
 => ArithB (m a)
 -> Op (InfixA MulOp) (Op (InfixA PowOp) (m a))
arithMul (ArithB a) = getTerm a

arithTerm :: MonadFree ArithB m => ArithB (m a) -> m a
arithTerm (ArithB (TermIL (TermIL (TermIR a)))) = a
arithTerm a                                     = wrap a
  
class ArithB_ r where
  (#+) :: r -> r -> r
  (#-) :: r -> r -> r
  (#*) :: r -> r -> r
  (#/) :: r -> r -> r
  (#^) :: r -> r -> r
    
instance ArithB_ (ArithB a) where
  a #+ b = Ex (infixL (:#+) (runFreeT (runFreeT a) b)
  a #- b = OpT (infixL (:#-) a b)
  a #* b =
    OpT (Term (infixL (:#*) (getTerm a) (getTerm b)))
  OpT a #/ OpT b =
    OpT (Term (infixL (:#/) (getTerm a) (getTerm b)))
  OpT a #^ OpT b =
    (OpT . Term . Term)
      (infixR (:#^)
        (getTerm (getTerm a))
        (getTerm (getTerm b)))

{-
instance MonadFree ArithB m => ArithB_ (ArithB m a) where
  ArithB a #+ ArithB b = ArithB (infixL (:#+) a b)
  a #- b = ArithB (InfixL (arithAdd a :#- arithMul b))
  a #* b = ArithB (TermIL (InfixL (arithMul a :#* arithPow b)))
  a #/ b = ArithB (TermIL (InfixL (arithMul a :#/ arithPow b)))
  a #^ b = ArithB (TermIL (TermIL (InfixR (arithTerm a :#^ arithPow b))))

arithAdd
 :: ArithB a
 -> Op (InfixA AddOp) (Op (InfixA MulOp) (Op (InfixR PowOp) a))
arithAdd (ArithB a) = a

arithMul
 :: MonadFree (Op (InfixA AddOp)) (Op (InfixA MulOp))
 => ArithB (m a)
 -> Op (InfixA MulOp) (Op (InfixA PowOp) (m a))
arithMul (ArithB a) = getTerm a

arithPow
 :: MonadFree ArithB m
 => ArithB (m a)
 -> InfixR PowOp (m a)
arithPow (ArithB (TermIL (TermIL a))) = a
arithPow a                            = TermIR (wrap a)

arithTerm :: MonadFree ArithB m => ArithB (m a) -> m a
arithTerm (ArithB (TermIL (TermIL (TermIR a)))) = a
arithTerm a                                     = wrap a
-}
  
  
showArithB
 :: (a -> ShowS) -> ArithB (F ArithB) a -> ShowS
showArithB showa = showArithB' (\ f -> 
  runF f showa (showParen True . showArithB' id))
  where 
    showArithB' :: (a -> ShowS) -> ArithB a -> ShowS
    showArithB' showa (ArithB opl) =
      fromBinopL showAddOp (fromBinopL showMulOp (fromBinopR showPowOp showa)) opl

  
  
-- | Parse an expression observing operator precedence
parseArithB :: ArithB_ r => Parser r -> Parser r
parseArithB p = parseAdd p where
  parseAdd p = Parsec.chainl1 (parseMul p) addOp where 
    addOp =
      (parseSymbol Add >> return (#+))
        <|> (parseSymbol Sub >> return (#-))
        
  parseMul p = Parsec.chainl1 (parsePow p) mulOp where
    mulOp =
      (parseSymbol Mul >> return (#*))
        <|> (parseSymbol Div >> return (#/))
        
  parsePow p = Parsec.chainr1 p powOp where
    powOp = parseSymbol Pow >> return (#^)

    
fromArithB :: ArithB_ r => ArithB (F ArithB r) -> r
fromArithB = fromArithB' (iter (fromArithB' id))
  where
    fromArithB'
     :: ArithB_ r => (a -> r) -> ArithB a -> r
    fromArithB' f (ArithB opl) =
      fromBinopL fromAddOp (fromBinopL fromMulOp (fromBinopR fromPowOp f)) opl
    
    fromAddOp
     :: ArithB_ r => (a -> r) -> (b -> r) -> AddOp a b -> r
    fromAddOp f g (a :#+ b) = f a #+ g b
    fromAddOp f g (a :#- b) = f a #- g b
    
    fromMulOp
     :: ArithB_ r => (a -> r) -> (b -> r) -> MulOp a b -> r
    fromMulOp f g (a :#* b) = f a #* g b
    fromMulOp f g (a :#/ b) = f a #/ g b
    
    fromPowOp :: ArithB_ r => (a -> r) -> (b -> r) -> PowOp a b -> r
    fromPowOp f g (a :#^ b) = f a #^ g b
    
    
data CmpOp a b =
    a :#== b
  | a :#!= b
  | a :#<  b
  | a :#<= b
  | a :#>  b
  | a :#>= b
  deriving (Eq, Show)
  
showCmpOp
 :: (a -> ShowS) -> (b -> ShowS) -> CmpOp a b -> ShowS
showCmpOp f g (a :#== b) = showInfix f g Eq a b
showCmpOp f g (a :#!= b) = showInfix f g Ne a b
showCmpOp f g (a :#<  b) = showInfix f g Lt a b
showCmpOp f g (a :#<= b) = showInfix f g Le a b
showCmpOp f g (a :#>  b) = showInfix f g Gt a b
showCmpOp f g (a :#>= b) = showInfix f g Ge a b

instance Bifunctor CmpOp where
  bimap f g (a :#== b) = f a :#== g b
  bimap f g (a :#!= b) = f a :#!= g b
  bimap f g (a :#<  b) = f a :#<  g b
  bimap f g (a :#<= b) = f a :#<= g b
  bimap f g (a :#>  b) = f a :#>  g b
  bimap f g (a :#>= b) = f a :#>= g b


type CmpB = Infix CmpOp
  
cmpTerm
 :: MonadFree CmpB m
 => CmpB (m a)
 -> m a
cmpTerm (TermI a) = a
cmpTerm a         = wrap a
  
class CmpB_ r where
  (#==) :: r -> r -> r
  (#!=) :: r -> r -> r
  (#>)  :: r -> r -> r
  (#<)  :: r -> r -> r
  (#>=) :: r -> r -> r
  (#<=) :: r -> r -> r
  
instance MonadFree CmpB m => CmpB_ (CmpB (m a)) where
  a #== b = Infix (cmpTerm a :#== cmpTerm b)
  a #!= b = Infix (cmpTerm a :#!= cmpTerm b)
  a #>  b = Infix (cmpTerm a :#>  cmpTerm b)
  a #>= b = Infix (cmpTerm a :#>= cmpTerm b)
  a #<  b = Infix (cmpTerm a :#<  cmpTerm b)
  a #<= b = Infix (cmpTerm a :#<= cmpTerm b)

showCmpB
 :: (a -> ShowS) -> CmpB (F CmpB a) -> ShowS
showCmpB showa = fromBinopA showCmpOp (\ (F f) ->
  f showa (showParen True . fromBinopA showCmpOp id))
  
parseCmpB :: CmpB_ r => Parser r -> Parser r
parseCmpB p =
  do
    a <- p
    (do
       s <- cmpOp
       b <- p
       return (s a b))
      <|> return a
  where
    cmpOp = 
      (parseSymbol Gt >> return (#>))
        <|> (parseSymbol Lt >> return (#<))
        <|> (parseSymbol Eq >> return (#==))
        <|> (parseSymbol Ne >> return (#!=))
        <|> (parseSymbol Ge >> return (#>=))
        <|> (parseSymbol Le >> return (#<=))

    
fromCmpB :: CmpB_ r => CmpB (F CmpB r) -> r
fromCmpB = fromBinopA fromCmpOp (iter (fromBinopA fromCmpOp id))
  where
    fromCmpOp
     :: CmpB_ r => (a -> r) -> (b -> r) -> CmpOp a b -> r
    fromCmpOp f g (a :#== b) = f a #== g b
    fromCmpOp f g (a :#!= b) = f a #!= g b
    fromCmpOp f g (a :#>  b) = f a #> g b
    fromCmpOp f g (a :#>= b) = f a #>= g b
    fromCmpOp f g (a :#<  b) = f a #< g b
    fromCmpOp f g (a :#<= b) = f a #<= g b
   
    
    
data AndOp a b = a :#&& b
  deriving (Eq, Show)

showAndOp :: (a -> ShowS) -> (b -> ShowS) -> AndOp a b -> ShowS
showAndOp f g (a :#&& b) = showInfix f g And a b

instance Bifunctor AndOp where
  bimap f g (a :#&& b) = f a :#&& g b

data OrOp a b = a :#|| b
  deriving (Eq, Show)

showOrOp :: (a -> ShowS) -> (b -> ShowS) -> OrOp a b -> ShowS
showOrOp f g (a :#|| b) = showInfix f g Or a b

instance Bifunctor OrOp where
  bimap f g (a :#|| b) = f a :#|| g b

newtype LogicB a = LogicB (InfixR OrOp (InfixR AndOp a))
  deriving (Eq, Show, Functor)

logicOr :: LogicB a -> InfixR OrOp (InfixR AndOp a)
logicOr (LogicB a) = a

logicAnd
 :: MonadFree LogicB m
 => LogicB (m a)
 -> InfixR AndOp (m a)
logicAnd (LogicB (TermIR a)) = a
logicAnd a                   = TermIR (wrap a)

logicTerm
 :: MonadFree LogicB m => LogicB (m a) -> m a
logicTerm (LogicB (TermIR (TermIR a))) = a
logicTerm a                            = wrap a

class LogicB_ r where
  (#&&) :: r -> r -> r
  (#||) :: r -> r -> r
  
instance MonadFree LogicB m => LogicB_ (LogicB (m a)) where
  a #|| b = LogicB (InfixR (logicAnd a :#|| logicOr b))
  a #&& b = LogicB (TermIR (InfixR (logicTerm a :#&& logicAnd b)))
  
showLogicB :: (a -> ShowS) -> LogicB (F LogicB a) -> ShowS
showLogicB showa = showLogicB' (\ (F f) -> 
  f showa (showParen True . showLogicB' id))
  where
    showLogicB' :: (a -> ShowS) -> LogicB a -> ShowS
    showLogicB' showa (LogicB opr) =
      fromBinopR showOrOp (fromBinopR showAndOp showa) opr

parseLogicB :: LogicB_ r => Parser r -> Parser r
parseLogicB = parseOr
  where
    parseOr p = Parsec.chainr1 (parseAnd p) orOp where
      orOp = parseSymbol Or >> return (#||)
    
    parseAnd p = Parsec.chainr1 p andOp where
      andOp = parseSymbol And >> return (#&&)
      
fromLogicB :: LogicB_ r => LogicB (F LogicB r) -> r
fromLogicB = fromLogicB' (iter (fromLogicB' id)) where
  fromLogicB' :: LogicB_ r => (a -> r) -> LogicB a -> r
  fromLogicB' froma (LogicB opr) =
    fromBinopR fromOrOp (fromBinopR fromAndOp froma) opr
  
  fromOrOp f g (a :#|| b) = f a #|| g b
  fromAndOp f g (a :#&& b) = f a #&& g b
