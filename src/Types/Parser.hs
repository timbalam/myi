module Types.Parser
  ( FieldId(..)
  , Lval(..)
  , Pattern(..)
  , DestructureBody
  , Lstmt0(..)
  , Lstmt1(..)
  , Selection(..)
  , SelectionPattern0(..)
  , Description0Body
  , SelectionPattern1(..)
  , Description1Body
  , Match0(..)
  , Match1(..)
  , SelectionPattern(..)
  , Rval(..)
  , StructureBody
  , Stmt(..)
  , PackEnv(..)
  , Unop(..)
  , Binop(..)
  ) where
import Data.Char
  ( showLitChar )
import Data.Foldable
  ( foldl' )
import Data.List.NonEmpty
  ( NonEmpty(..)
  )
import Types.Util.List
  ( Prefix(..)
  , Suffix(..)
  )
  

class ShowMy a where
  showMy :: a -> String
  showMy x = showsMy x ""
  
  showsMy :: a -> String -> String
  showsMy x s = showMy x ++ s
  
  
-- | Print a literal string
showLitString [] s =
  s

showLitString ('"' : cs) s =
  "\\\"" ++ (showLitString cs s)

showLitString (c   : cs) s =
  showLitChar c (showLitString cs s)
   
   
-- | My-language field identifiers
newtype FieldId = Field String
  deriving (Eq, Ord)

  
instance Show FieldId where
  showsPrec _ (Field s) =
    showLitString s
  
  
-- | My-language lval
data Lval =
    InEnv FieldId
  | InSelf FieldId
  | Lval `In` FieldId
  deriving Eq
  
  
type DestructureBody =
  Prefix
    (Either
      (Suffix Lstmt1 Lstmt0)
      Lstmt0)
    Lstmt0
  

data Pattern =
    Address Lval
  | Destructure DestructureBody
  deriving Eq
  
  
data Lstmt0 =
    SelectionPattern0 `As` Pattern
  | AsPun Lval
  deriving Eq
  
  
data Lstmt1 =
    SelectionPattern1 `AsP` Pattern
  | UnpackRemaining
  deriving Eq
  
  
instance Show Lval where
  show (InEnv x) =
    show x
    
  show (InSelf x) =
    "." ++ show x
  
  show (y `In` x) =
    show y ++ "." ++ show x
    

instance Show Pattern where
  show (Address x) =
    show x
    
  show (Destructure (xs :<: a)) =
    "{ "
      ++ foldMap (\ x -> show x ++ "; ") xs
      ++ go a
      ++ " }"
      where
        go (Left (b :>: xs)) =
          show b ++ foldMap (\ x -> "; " ++ show x) xs
          
        go (Right x) =
          show x
    
    
instance Show Lstmt0 where
  show (r `As` l) =
    show r ++ " = " ++ show l
    
  show (AsPun l) =
    show l
    
    
instance Show Lstmt1 where
  show (r `AsP` l) =
    show r ++ " = " ++ show l
    
  show UnpackRemaining =
    "..."
  

-- | Mylanguage plain value without pack  
data Selection =
    SelectSelf FieldId
  | Selection `Select` FieldId
  deriving Eq
  
  
type Description0Body =
  NonEmpty Match0
  

data SelectionPattern0 =
    AddressS Selection
  | Description Description0Body
  deriving Eq
  
  
data SelectionPattern =
    Plain SelectionPattern0
  | Packed SelectionPattern1
  deriving Eq
  
  
data Match0 =
    SelectionPattern `Match` SelectionPattern0
  | MatchPun Selection
  deriving Eq
  

instance Show Selection where
  show (SelectSelf x) =
    "." ++ show x
    
  show (y `Select` x) =
    show y ++ "." ++ show x
    
    
instance Show SelectionPattern0 where
  show (AddressS x) =
    show x
    
  show (Description (x :| xs)) =
    "{ "
      ++ foldl' (\ b a -> b ++ "; " ++ show a) (show x) xs
      ++ " }"
      
      
instance Show SelectionPattern where
  show (Plain x) =
    show x
    
  show (Packed x) = 
    show x
      
      
instance Show Match0 where
  show (l `Match` r) =
    show l ++ " = " ++ show r

  show (MatchPun l) =
    show l
    
    
type Description1Body =
  Prefix
    (Suffix Match1 Match0)
    Match0
    
    
newtype SelectionPattern1 =
  DescriptionP Description1Body
  deriving Eq
  
  
data Match1 =
    SelectionPattern `MatchP` SelectionPattern1
  | RepackRemaining
  deriving Eq
    
    
instance Show SelectionPattern1 where
  show (DescriptionP (xs :<: b :>: ys)) = 
    "{"
      ++ foldMap (\ x -> show x ++ "; ") xs
      ++ show b
      ++ foldMap (\ y -> "; " ++ show y) ys
      ++ "}"

        
instance Show Match1 where
  show (l `MatchP` r) =
    show l ++ " = " ++ show r
    
  show RepackRemaining =
    "..."
  
  
-- | My language rval
type StructureBody =
  Prefix 
    (Maybe (Suffix PackEnv Stmt))
    Stmt
    
        
data Rval =
    IntegerLit Integer
  | NumberLit Double
  | StringLit (NonEmpty String)
  | GetEnv FieldId
  | GetSelf FieldId
  | Rval `Get` FieldId
  | Structure StructureBody
  | Rval `Apply` Rval
  | Unop Unop Rval
  | Binop Binop Rval Rval
  | Import Rval
  deriving Eq

  
data Stmt =
    Declare Lval
  | SetPun Lval
  | Pattern `Set` Rval
  | Run Rval
  deriving Eq
  
  
data PackEnv =
  PackEnv
  deriving Eq

  
data Unop =
    Neg
  | Not
  deriving Eq
  
  
data Binop =
    Add
  | Sub
  | Prod
  | Div
  | Pow
  | And
  | Or
  | Lt
  | Gt 
  | Eq
  | Ne
  | Le
  | Ge
  deriving Eq

  
instance Show Rval where
  show (IntegerLit n) =
    show n
    
  show (NumberLit n) =
    show n
  
  show (StringLit (x:|xs)) =
    show x
      ++ foldMap (\ a -> " " ++ show a) xs
  
  show (GetEnv x) =
    show x
  
  show (GetSelf x) =
    "." ++ show x
  
  show (y `Get` x) =
    show y ++ "." ++ show x
  
  show (Structure ([] :<: Nothing)) =
    "{}"
  
  show (Structure body) =
    "{ "
      ++ go body
      ++ " }"
      where
        go ([] :<: Just (b :>: xs)) =
          showsuff b xs
          
        go (x : xs :<: Just (b :>: ys)) =
          showsuff x xs 
            ++ "; "
            ++ showsuff b ys
          
        go (x : xs :<: Nothing) =
          showsuff x xs
          
          
        showsuff b xs =
          show b 
            ++ foldMap (\ x -> "; " ++ show x) xs
          
            
  show (a `Apply` b) =
    show a ++ "(" ++ show b ++ ")"
  
  show (Unop s a@(Binop _ _ _)) =
    show s ++ "(" ++ show a ++ ")"
  
  show (Unop s a) =
    show s ++ show a
  
  show (Binop s a@(Binop _ _ _) b@(Binop _ _ _)) =
    "(" ++ show a ++ ") " ++ show s ++ " (" ++ show b ++ " )"
  
  show (Binop s a@(Binop _ _ _) b) =
    "(" ++ show a ++ ") " ++ show s ++ " " ++ show b
  
  show (Binop s a b@(Binop _ _ _)) =
    show a ++ " " ++ show s ++ " (" ++ show b ++ ")"
  
  show (Binop s a b) =
    show a ++ show s ++ show b
  
  show (Import s) =
    "#from " ++ show s

    
instance Show Stmt where
  show (Declare l) =
    show  l ++ " ="
    
  show (SetPun l) =
    show l
  
  show (l `Set` r) =
    show l ++ " = " ++  show r
  
  show (Run r) =
     "#run " ++ show r
     
     
instance Show PackEnv where
  show PackEnv =
    "..."


instance Show Unop where
  showsPrec _ Neg =
    showLitChar '-'
  
  showsPrec _ Not =
    showLitChar '!'


instance Show Binop where
  showsPrec _ Add =
    showLitChar '+'
  
  showsPrec _ Sub =
    showLitChar '-'
  
  showsPrec _ Prod =
    showLitChar '*'
  
  showsPrec _ Div =
    showLitChar '/'
  
  showsPrec _ Pow =
    showLitChar '^'
  
  showsPrec _ And =
    showLitChar '&'
  
  showsPrec _ Or =
    showLitChar '|'
  
  showsPrec _ Lt =
    showLitChar '<'
  
  showsPrec _ Gt =
    showLitChar '>'
  
  showsPrec _ Eq =
    showLitString "=="
  
  showsPrec _ Ne =
    showLitString "!="
  
  showsPrec _ Le =
    showLitString "<="
  
  showsPrec _ Ge =
    showLitString ">="
