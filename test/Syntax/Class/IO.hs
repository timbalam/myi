module Syntax.Class.IO
  ( tests
  )
  where

import qualified IO (tests)
import My.Eval (K)
import My.Builtin (builtins)
import My.Types.Expr (Expr, Ident, Nec, Key)
import qualified My.Types.Parser as P
import My.Syntax (ScopeError(..), applybuiltins, loadexpr)
import My.Syntax.Expr (E)
import Data.Void (Void)
import Data.Functor.Identity (Identity)
  
parses
  :: E (Expr K Identity (P.Vis (Nec Ident) Key))
  -> IO (Either [ScopeError] (Expr K Identity Void))
parses e = applybuiltins builtins <$> loadexpr (pure e) []

tests = IO.tests parses