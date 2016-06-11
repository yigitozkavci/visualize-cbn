{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module CBN.Parser (
    parseTerm
  , term
  , parseIO
  ) where

import Control.Exception
import Control.Monad
import Language.Haskell.TH (Q)
import Language.Haskell.TH.Quote
import Text.Parsec
import Text.Parsec.Language (haskellDef)
import Text.Parsec.Pos (newPos)
import Text.Parsec.String
import qualified Text.Parsec.Token   as P
import qualified Language.Haskell.TH as TH

import CBN.Language
import CBN.Heap

{-------------------------------------------------------------------------------
  Quasi-quotation
-------------------------------------------------------------------------------}

term :: QuasiQuoter
term = QuasiQuoter {
      quoteExp = \str -> do
        l <- location
        c <- TH.runIO $ parseIO "splice" (setPosition l *> parseTerm) str
        dataToExpQ (const Nothing) c
    , quotePat  = undefined
    , quoteType = undefined
    , quoteDec  = undefined
    }

{-------------------------------------------------------------------------------
  Individual parsers
-------------------------------------------------------------------------------}

parseVar :: Parser Var
parseVar = Var <$> identifier <?> "variable"

parseCon :: Parser Con
parseCon = (lexeme $ mkCon <$> upper <*> many alphaNum) <?> "constructor"
  where
    mkCon x xs = Con (x:xs)

parsePat :: Parser Pat
parsePat = Pat <$> parseCon <*> many parseVar

parseMatch :: Parser Match
parseMatch = Match <$> parsePat <* reservedOp "->" <*> parseTerm

-- | Parse a pointer
--
-- The only pointers we expect in initial terms are ones that refer to the
-- initial heap (the prelude)
parsePtr :: Parser Ptr
parsePtr = mkPtr <$ char '@' <*> identifier
  where
    mkPtr name = Ptr Nothing (Just name)

parseTerm :: Parser Term
parseTerm = msum [
      TCon  <$> parseCon  <*> many go
    , TPrim <$> parsePrim <*> many go
    , nTApp <$> many1 go
    ] <?> "term"
  where
    -- terms without top-level application
    go :: Parser Term
    go = msum [
          unaryTPrim <$> parsePrim
        , unaryTCon  <$> parseCon
        , TPtr  <$> parsePtr
        , TLam  <$  reservedOp "\\"
                <*> parseVar
                <*  reservedOp "->"
                <*> parseTerm
        , TLet  <$  reserved "let"
                <*> parseVar
                <*  reservedOp "="
                <*> parseTerm
                <*  reservedOp "in"
                <*> parseTerm
        , TCase <$  reserved "case"
                <*> parseTerm
                <*  reserved "of"
                <*> braces (parseMatch `sepBy` reservedOp ";")
        , TVar  <$> parseVar
        , parens parseTerm
        ]

    unaryTPrim :: Prim -> Term
    unaryTPrim p = TPrim p []

    unaryTCon :: Con -> Term
    unaryTCon c = TCon c []

parsePrim :: Parser Prim
parsePrim   = msum [
      PInt  <$> natural
    , PIAdd <$  reserved "add"
    , PILt  <$  reserved "lt"
    , PIEq  <$  reserved "eq"
    , PILe  <$  reserved "le"
    ]

{-------------------------------------------------------------------------------
  Lexical analysis
-------------------------------------------------------------------------------}

lexer = P.makeTokenParser haskellDef {
      P.reservedNames   = ["case", "of", "let", "in", "add", "lt", "eq", "le"]
    , P.reservedOpNames = ["\\", "->", ";", "@", "="]
    }

braces     = P.braces     lexer
identifier = P.identifier lexer
lexeme     = P.lexeme     lexer
natural    = P.natural    lexer
parens     = P.parens     lexer
reservedOp = P.reservedOp lexer
reserved   = P.reserved   lexer
whiteSpace = P.whiteSpace lexer

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

parseTopLevel :: Parser a -> Parser a
parseTopLevel p = whiteSpace *> p <* eof

parseIO :: String -> Parser a -> String -> IO a
parseIO input p str =
  case parse (parseTopLevel p) input str of
    Left err -> throwIO (userError (show err))
    Right a  -> return a

location :: Q SourcePos
location = aux <$> TH.location
  where
    aux :: TH.Loc -> SourcePos
    aux loc = uncurry (newPos (TH.loc_filename loc)) (TH.loc_start loc)
