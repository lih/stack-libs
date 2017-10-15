{-# LANGUAGE CPP, ExistentialQuantification, ViewPatterns, RecursiveDo #-}
module Curly.Session.Commands.Query where

import Curly.Core
import Curly.Core.Annotated
import Curly.Core.Library
import Curly.UI
import Curly.Core.Parser
import Curly.Style
import Language.Format hiding (space)
import Curly.Session.Commands.Common

whereCmd,whyCmd,whatCmd,howCmd :: Interactive Command

viewCmd doc onExpr onPath showV = withDoc doc . fill False $ (several "'s" >> viewSym) <+? viewPath
  where viewPath = nbsp >> do
          path <- liftA2 subPath (getSession wd) dirArgs
          withMountain $ case localContext^?atMs path of
            Just (Pure (_,v)) -> liftIOWarn $ showV path v
            _ -> onPath path
                 <+? serveStrLn ("Error: "+showPath path+" isn't a function.")
        viewSym = (nbsp >>) . (<+? onExpr) $ do
          n <- dirArg
          lookingAt (eoi+eol)
          l <- getSession this
          liftIOWarn $ case l^.symbols.at n of
            Just s -> showV [] s
            _ -> serveStrLn $ "Error: "+n+": no such symbol."

whyDoc = unlines [
  "{section {title Show Function Documentation}"
  ,"{p {em Usage:} why PATH {em OR} why's NAME}"
  ,"{p Show the documentation for the function at PATH, or of the symbol NAME.}}"
  ]
whyCmd = viewCmd whyDoc zero (const zero) $ \_ (by leafDoc -> d) ->
  setupTermFromEnv >>= \t -> withStyle (serveStrLn $ docString t d)

howDoc = unlines [
  "{section {title Show Function Implementation}"
  ,"{p {em Usage:} how PATH {em OR} how's EXPR}"
  ,"{p Show the implementation of the function at PATH, or an expression EXPR in the local context.}}"
  ]
data VerboseVar = VerboseVar GlobalID (Maybe Int)
instance Show (Pretty VerboseVar) where
  show (Pretty (VerboseVar v n)) = pretty v+maybe "" (\x -> "["+show x+"]") n
serveHow v | envLogLevel>=Verbose = serveStrLn (pretty (map withSym (semantic v) :: Expression GlobalID VerboseVar))
           | otherwise = serveStrLn (pretty (map fst (semantic v) :: Expression GlobalID GlobalID))
  where withSym (s,Pure (Argument n)) = VerboseVar s (Just n)
        withSym (s,_) = VerboseVar s Nothing
howCmd = viewCmd howDoc onExpr (const zero) $ \_ (by leafVal -> v) -> serveHow v
  where onExpr = do
          e <- optimized =<< accessorExpr hspace
          serveHow e
          
whatDoc = unlines [
  "{section {title Show Function Type}"
  ,"{p {em Usage:} what PATH {em OR} what's EXPR}"
  ,"{p Show the type of the function at PATH, or an expression EXPR in the local context.}}"
  ]
whatCmd = viewCmd whatDoc onExpr (const zero) $ \_ (by leafVal -> v) -> serveWhat v
  where serveWhat v = let (t,isC) = exprType v
                      in serveStrLn ((if isC then "Complex\n" else "") + show t)
        onExpr = do
          e <- optimized =<< accessorExpr hspace
          serveWhat e

rangeFile :: Traversal' SourceRange String
rangeFile k (SourceRange (Just s) a b) = k s <&> \s' -> SourceRange (Just s') a b
rangeFile _ x = pure x

whereDoc = unlines [
  "{section {title Go To Function}"
  ,"{p {em Usage:} where PATH}"
  ,"{p Start an editing session for the function at PATH.}}"
  ]
whereCmd = viewCmd whereDoc zero onPath $ \path (by leafPos -> r) -> case r of
  SourceRange (Just f) (_,l,c) _ -> editSource f (l,c) reloadMountain
  _ -> serveStrLn $ "No source position available for "+showPath path 
  where onPath p = withMountain $ do
          case ?mountain^?atMs p.t'Pure.flLibrary.symbols.traverse.leafPos.rangeFile of
            Just s -> liftIOWarn $ editSource s (0,0) reloadMountain
            _ -> zero
