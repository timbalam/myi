{-# LANGUAGE OverloadedStrings #-}
module Goat.Interpreter.Browse where

import Goat.Lang.Parser (definition, tokens, eof)
import Goat.Repr.Lang.Expr (getDefinition)
import Goat.Repr.Eval.Dyn
  ( checkExpr, eval
  , DynError, StaticError(..), ImportError(..), Dyn, Repr
  , Import(..), VarName
  , displayImportError, displayValue
  )
import Goat.Repr.Pattern (Ident, Identity, Multi)
import Data.Bifunctor (bimap)
--import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Text (Text)
import Data.Void (Void)
import System.IO (hFlush, stdout, FilePath)
import Text.Parsec (parse)
-- import qualified Text.Parsec as Parsec


-- | Enter read-eval-print loop
browse
  :: IO ()
browse = first where
  first = getPrompt ">> " >>= rest

  rest ":q" = return ()
  rest s =
    putStrLn
      (either
        displayImportError
        (displayValue . snd . checkExpr)
        (parseExpr s))
    >> first
   

-- | Parse and check expression

parseExpr
  :: Text
  -> Either ImportError
      (Repr (Multi Identity) (VarName Ident Ident (Import Ident)))
parseExpr t =
  bimap
    ParseError
    getDefinition
    (parse tokens "myi" t >>=
      parse (definition <* eof) "myi")
  

-- Console / Import --
flushStr :: Text -> IO ()
flushStr s =
  Text.putStr s >> hFlush stdout

getPrompt :: Text -> IO Text
getPrompt prompt =
  flushStr prompt >> Text.getLine
