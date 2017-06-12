module Types.Parser
  ( Ident(..)
  , Route(..)
  , Laddress(..)
  , Lval(..)
  , PlainRoute(..)
  , ReversibleStmt(..)
  , Rval(..)
  , Stmt(..)
  , Unop(..)
  , Binop(..)
  ) where
import Data.Char
  ( showLitChar )
import Data.Foldable
  ( foldl' )
  
-- | Print a literal string
showLitString []         s = s
showLitString ('"' : cs) s = "\\\"" ++ (showLitString cs s)
showLitString (c   : cs) s = showLitChar c (showLitString cs s)
    
-- | My-language identifiers
newtype Ident = Ident String
  deriving (Eq, Ord)

instance Show Ident where
  showsPrec _ (Ident s) = showLitString s
  
data Route a = Atom Ident | Route a Ident
  deriving Eq
  
instance Show a => Show (Route a) where
  show (Atom x) = show x
  show (Route y x) = show y ++ show x
  
-- | My-language lval
data Laddress = Lident Ident | Lroute (Route Laddress)
  deriving Eq
data Lval = Laddress Laddress | Lnode [ReversibleStmt]
  deriving Eq
data PlainRoute = PlainRoute (Route PlainRoute)
  deriving Eq
data ReversibleStmt = ReversibleAssign PlainRoute Lval | ReversibleUnpack Lval
  deriving Eq

instance Show Laddress where
  show (Lident x) = show x
  show (Lroute x) = show x
instance Show Lval where
  show (Laddress x) = show x
  show (Lnode (x:xs)) = "{ " ++ foldl' (\b a -> b ++ "; " ++ show a) (show x) xs ++ " }"
instance Show PlainRoute where
  show (PlainRoute x) = show x
instance Show ReversibleStmt where
  show (ReversibleAssign r l) = show r ++ " = " ++ show l
  show (ReversibleUnpack l) = "*" ++ show l
  
-- | My language rval
data Rval = Number Double | String String | Rident Ident | Rroute (Route Rval) | Rnode [Stmt] | App Rval Rval | Unop Unop Rval | Binop Binop Rval Rval | Import Rval
  deriving Eq
data Stmt = Declare Laddress | Assign Lval Rval | Eval Rval | Unpack Rval
  deriving Eq
data Unop = Neg | Not
  deriving Eq
data Binop = Add | Sub | Prod | Div | Pow | And | Or | Lt | Gt | Eq | Ne | Le | Ge
  deriving Eq

instance Show Rval where
  show (Number n) = show n
  show (String s) = show s
  show (Rident x) = show x
  show (Rroute x) = show x
  show (Rnode []) = "{}"
  show (Rnode (x:xs)) = "{ " ++ foldl' (\b a -> b ++ "; " ++ show a) (show x) xs ++ " }"
  show (App a b) = show a ++ "(" ++ show b ++ ")"
  show (Unop s a@(Binop _ _ _)) = show s ++ "(" ++ show a ++ ")"
  show (Unop s a) = show s ++ show a
  show (Binop s a@(Binop _ _ _) b@(Binop _ _ _)) = "(" ++ show a ++ ") " ++ show s ++ " (" ++ show b ++ " )"
  show (Binop s a@(Binop _ _ _) b) = "(" ++ show a ++ ") " ++ show s ++ " " ++ show b
  show (Binop s a b@(Binop _ _ _)) = show a ++ " " ++ show s ++ " (" ++ show b ++ ")"
  show (Binop s a b) = show a ++ show s ++ show b
  show (Import s) = "from " ++ show s
instance Show Stmt where
  show (Declare l) = show  l ++ " ="
  show (Assign l r) = show l ++ " = " ++  show r
  show (Eval r) = show r
  show (Unpack r) = "*" ++ show r
instance Show Unop where
  showsPrec _ Neg = showLitChar '-'
  showsPrec _ Not = showLitChar '!'
instance Show Binop where
  showsPrec _ Add  = showLitChar '+'
  showsPrec _ Sub  = showLitChar '-'
  showsPrec _ Prod = showLitChar '*'
  showsPrec _ Div  = showLitChar '/'
  showsPrec _ Pow  = showLitChar '^'
  showsPrec _ And  = showLitChar '&'
  showsPrec _ Or   = showLitChar '|'
  showsPrec _ Lt   = showLitChar '<'
  showsPrec _ Gt   = showLitChar '>'
  showsPrec _ Eq   = showLitString "=="
  showsPrec _ Ne   = showLitString "!="
  showsPrec _ Le   = showLitString "<="
  showsPrec _ Ge   = showLitString ">="
