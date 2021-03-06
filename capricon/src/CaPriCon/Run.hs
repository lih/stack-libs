{-# LANGUAGE CPP, NoMonomorphismRestriction, OverloadedStrings, ScopedTypeVariables, DeriveGeneric, ConstraintKinds, UndecidableInstances, PatternSynonyms #-}
module CaPriCon.Run where

import Definitive
import Language.Format
import Algebra.Monad.Concatenative
import Data.CaPriCon
import Data.CaPriCon.Extraction (Algebraic(..),fromTerm)
import GHC.Generics (Generic)

class Monad m => MonadSubIO io m where
  liftSubIO :: io a -> m a
instance MonadSubIO IO IO where liftSubIO = id
instance MonadSubIO io m => MonadSubIO io (ConcatT st b o s m) where
  liftSubIO ma = lift $ liftSubIO ma

type COCAxiom str = str
type MaxDelta = Int
type UniverseConstraint = [Maybe MaxDelta]
data UniverseConstraints = UniverseConstraints [UniverseConstraint]
instance Semigroup UniverseConstraints where
  UniverseConstraints x + UniverseConstraints y = UniverseConstraints $ zipWith (zipWith (\_x _y -> zipWith max _x _y + _x + _y)) x y
instance Monoid UniverseConstraints where zero = UniverseConstraints (repeat (repeat Nothing))
data COCValue io str = COCExpr (ContextTerm str (COCAxiom str))
                     | COCNull | COCError str
                     | COCConvertible (Maybe (Int,Int))
                     | COCAlgebraic (Algebraic str)
                     | COCDir (NodeDir str (COCAxiom str) ([str],StackVal str (COCBuiltin io str) (COCValue io str)))
                     deriving Generic
instance ListSerializable ClosureAction ; instance ListFormat ClosureAction
instance (ListSerializable s,ListSerializable b,ListSerializable a) => ListSerializable (StackStep s b a)
instance (ListSerializable s,ListSerializable b,ListSerializable a) => ListSerializable (StackClosure s b a)
instance (ListSerializable s,ListSerializable b,ListSerializable a) => ListSerializable (StackVal s b a)
instance (IsCapriconString s,ListFormat s,ListFormat b,ListFormat a) => ListFormat (StackStep s b a)
instance (IsCapriconString s,ListFormat s,ListFormat b,ListFormat a) => ListFormat (StackClosure s b a)
instance (IsCapriconString s,ListFormat s,ListFormat b,ListFormat a) => ListFormat (StackVal s b a)
instance (ListSerializable b) => ListSerializable (StackBuiltin b)
instance (ListFormat b) => ListFormat (StackBuiltin b)
instance (ListSerializable a) => ListSerializable (Opaque a)
instance (ListFormat a) => ListFormat (Opaque a)
instance (ListSerializable s) => ListSerializable (StackComment s)
instance (ListFormat s) => ListFormat (StackComment s)

instance ListSerializable str => ListSerializable (COCValue io str)
instance (IsCapriconString str,ListFormat str,IOListFormat io str) => ListFormat (COCValue io str)
type COCDict io str = Map str (StackVal str (COCBuiltin io str) (COCValue io str))

pattern StackCOC v = StackExtra (Opaque v)

takeLast n l = drop (length l-n) l

showStackVal :: IsCapriconString str => (NodeDoc str -> str) -> NodeDir str (COCAxiom str) ([str],StringPattern str) -> [(str,Term str (COCAxiom str))] -> StackVal str (COCBuiltin io str) (COCValue io str) -> str
showStackVal toRaw dir ctx = fix $ \go _x -> case _x of
  StackCOC _x -> case _x of
    COCExpr (ContextTerm d e) -> -- "<"+show d+">:"+
      toRaw $ showNode' dir (map (second snd) $ takeLast d (freshContext ctx)) e
    COCNull -> "(null)"
    COCError e -> "<!"+e+"!>"
    COCDir d -> fromString $ show d
    COCConvertible conv -> fromString $ show conv
    COCAlgebraic a -> fromString $ show a
  StackSymbol s -> fromString $ show s
  StackInt n -> fromString $ show n
  StackList l -> "["+intercalate "," (map go l)+"]"
  StackDict d -> "[<"+intercalate "," (map (\(k,v) -> k+": "+go v) (d^.ascList))+">]"
  StackProg p ->
    let showStep (ConstStep x) = go x
        showStep (ExecStep x) = "$("+go x+")"
        showStep (ClosureStep b c) = fromString (show b)+":"+showClosure c
        showStep (VerbStep v) = v
        showStep (CommentStep (TextComment x)) = ":"+x
        showStep (CommentStep c) = ":<"+fromString (show c)+">"
        showSteps p' = intercalate " " (map showStep p')
        showClosure (StackClosure act cs c) =
          (case act of CloseExec -> "$" ; _ -> ",")
          +"{ "+intercalate " " (map (\(i,c') -> showSteps i+" "+showClosure c') cs + map showStep c)+" }"
    in "{ "+showSteps p+" }"
  _ -> fromString $ show _x
data COCBuiltin io str = COCB_Print | COCB_Quit
                       | COCB_Open (ReadImpl io str str) | COCB_Redirect (WriteImpl io str str)
                       | COCB_Cache (ReadImpl io str [Word8]) (WriteImpl io str [Word8])

                       | COCB_ToInt | COCB_Concat

                       | COCB_Bind Bool BindType
                       | COCB_Uni | COCB_Var | COCB_Mu | COCB_Ap | COCB_Axiom

                       | COCB_TypeOf | COCB_Convertible
                       | COCB_Extract | COCB_MatchTerm
                       
                       | COCB_Intro | COCB_Subst | COCB_Rename
                       | COCB_Pull

                       | COCB_ContextVars
                       | COCB_GetShowDir | COCB_SetShowDir | COCB_InsertNodeDir

                       | COCB_Format | COCB_Render
                       
                       deriving (Show,Generic)
data ReadImpl io str bytes = ReadImpl (str -> io (String :+: bytes))
data WriteImpl io str bytes = WriteImpl (str -> bytes -> io ())
instance Show (ReadImpl io str bytes) where show _ = "#<open>"
instance Show (WriteImpl io str bytes) where show _ = "#<write>"

type ListSerializable a = (Serializable [Word8] a)
type ListFormat a = (Format [Word8] a)
type IOListFormat io str = (ListFormat (ReadImpl io str str), ListFormat (WriteImpl io str str),
                            ListFormat (ReadImpl io str [Word8]), ListFormat (WriteImpl io str [Word8]))
instance Serializable [Word8] (ReadImpl io str bytes) where encode _ _ = zero
instance Serializable [Word8] (WriteImpl io str bytes) where encode _ _ = zero
instance ListSerializable str => ListSerializable (COCBuiltin io str)
instance (ListFormat str,IOListFormat io str) => ListFormat (COCBuiltin io str)

htmlQuote :: IsCapriconString str => str -> str
htmlQuote = fromString . foldMap qChar . toString
  where qChar '<' = "&lt;"
        qChar '>' = "&gt;"
        qChar '&' = "&amp;"
        qChar '"' = "&quot;"
        qChar c = [c]
stringWords :: IsCapriconString str => str -> [str]
stringWords x = [w | (True,w) <- stringWordsAndSpaces True x]

stringWordsAndSpaces :: IsCapriconString str => Bool -> str -> [(Bool,str)]
stringWordsAndSpaces unquoteStrings = map (second fromString) . fromBlank id . toString
  where fromBlank k (c:t) | c `elem` [' ', '\t', '\r', '\n'] = fromBlank (k.(c:)) t
                          | c == '"' = (False,k ""):fromQuote id t
                          | otherwise = (False,k ""):fromWChar (c:) t
        fromBlank k "" = [(False,k "")]
        fromQuote k ('"':t) = (True,'"':k "\""):fromBlank id t
        fromQuote k ('\\':c:t) | unquoteStrings = fromQuote (k.(qChar c:)) t
          where qChar 'n' = '\n' ; qChar 't' = '\t' ; qChar x = x
        fromQuote k (c:t) = fromQuote (k.(c:)) t
        fromQuote k "" = [(True,'"':k "\"")]
        fromWChar k (c:t) | c `elem` [' ', '\t', '\r', '\n'] = (True,k ""):fromBlank (c:) t
                          | otherwise = fromWChar (k.(c:)) t
        fromWChar k "" = [(True,k "")]

literate :: forall str. IsCapriconString str => Parser String [StackComment str :+: str]
literate = liftA2 (\pref r -> pref + [Left (TextComment $ fromString r)])
           (intercalate [Left (TextComment "\n")] <$> sepBy' (cmdline "> " ">? " <+? cmdline "$> " "$>? " <+? commentline) (single '\n'))
           remaining
  where
    cmdline :: Parser String () -> Parser String () -> Parser String [StackComment str :+: str]
    cmdline pre pre_ex = do
      indent <- many' (oneOf [' ','\t'])
      map (\(x,exs) -> [Left (TextComment $ fromString indent)
                       ,Left (BeginCodeParagraph (length x) (intercalate "\n" (map fst x)) exs)]
                       + map Right (foldMap snd x)
                       + [Left EndCodeParagraph])
        ((,) <$> sepBy1' go (single '\n') <*> option' [] ("\n" >> sepBy1' go_ex (single '\n')))
      where go = do pre; many' (noneOf ['\n']) <&> \x -> (fromString x,map fromString (stringWords x+["eol."]))
            go_ex = do pre_ex; many' (noneOf ['\n']) <&> fromString 
    commentline :: Parser String [StackComment str :+: str]
    commentline = map (foldMap ((pure . (Left . TextComment) <|>
                                 \(x,t) -> Left (BeginCodeSpan x):map Right t+[Left (EndCodeSpan x)])
                                <|> map Right))
      $ (<* lookingAt eol)
      $ many' (map (Left . Left . fromString)
                (many1' (noneOf ['{','\n']
                         <+? fill '{' (single '{' <* lookingAt (noneOf ['{','.']))))
               <+?
               map (Left . Right)
                (between "{{" "}}"
                  (many1' (noneOf ['}'] <+? fill '}' (single '}' <* lookingAt (noneOf ['}'])))
                   <&> \x -> (fromString x,stringWords (fromString x)+["mustache."])))
               <+?
               map Right
                (between "{." ".}"
                  (many1' (noneOf ['.'] <+? fill '.' (single '.' <* lookingAt (noneOf ['}']))))
                  <&> \x -> map fromString (stringWords x)))

data COCState str = COCState {
  _endState :: Bool,
  _context :: Env str (ContextTerm str (COCAxiom str)),
  _showDir :: NodeDir str (COCAxiom str) ([str],StringPattern str),
  _outputText :: str -> str
  }
endState :: Lens' (COCState str) Bool
endState = lens _endState (\x y -> x { _endState = y })
context :: Lens' (COCState str) (Env str (ContextTerm str (COCAxiom str)))
context = lens _context (\x y -> x { _context = y })
showDir :: Lens' (COCState str) (NodeDir str (COCAxiom str) ([str],StringPattern str))
showDir = lens _showDir (\x y -> x { _showDir = y })
outputText :: Lens' (COCState str) (str -> str)
outputText = lens _outputText (\x y -> x { _outputText = y })

pushError :: MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m => str -> m ()
pushError s = runStackState $ modify $ (StackCOC (COCError s):)

runInContext :: ax -> MaybeT ((->) ax) a -> Maybe a
runInContext c v = (v^..maybeT) c

modifyAllExprs :: MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m
               => (ContextTerm str (COCAxiom str) -> ContextTerm str (COCAxiom str)) -> m ()
modifyAllExprs f = do
  let modStack (StackCOC (COCExpr e)) = StackCOC (COCExpr (f e))
      modStack (StackDict d) = StackDict (map modStack d)
      modStack (StackList l) = StackList (map modStack l)
      modStack x = x
  runStackState $ modify $ map modStack
  runDictState $ modify $ map modStack
modifyCOCEnv :: MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m
          => Maybe (ContextTerm str (COCAxiom str) -> ContextTerm str (COCAxiom str),Env str (ContextTerm str (COCAxiom str))) -> m ()
modifyCOCEnv Nothing = unit
modifyCOCEnv (Just (modE,ctx)) = do
  runExtraState (context =- ctx)
  modifyAllExprs modE

execSymbolOrComment :: forall str io m.
                       (MonadSubIO io m,IsCapriconString str,
                        MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m,
                        IOListFormat io str,ListFormat str) =>
                       StackComment str :+: str -> m ()
execSymbolOrComment x = execSymbol (\b -> runCOCBuiltin b) outputComment $ (Comment <|> atomClass) x

runCOCBuiltin :: forall str io m.
                 (MonadSubIO io m,IsCapriconString str,
                  MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m,
                  IOListFormat io str,ListFormat str) =>
                 COCBuiltin io str -> m ()
runCOCBuiltin COCB_Quit = runExtraState (endState =- True)
runCOCBuiltin COCB_Print = do
  s <- runStackState get
  for_ (take 1 s) $ \case
    StackSymbol s' -> runExtraState (outputText =~ \o t -> o (s'+t))
    _ -> return ()

runCOCBuiltin COCB_Axiom = runStackState $ modify $ \case
  StackCOC (COCExpr (ContextTerm 0 e)):StackSymbol s:st -> StackCOC (COCExpr (ContextTerm 0 (Cons (Ap (Axiom e s) [])))):st
  st -> st

runCOCBuiltin COCB_Format = do
  ex <- runExtraState get
  let format ('%':'s':s) (StackSymbol h:t) = first (h+) (format s t)
      format ('%':'a':s) (StackSymbol h:t) = first (htmlQuote h+) (format s t)
      format ('%':'n':s) (StackSymbol h:t) = first (markSyntax h+) (format s t)
      format ('%':'v':s) (x:t) = first (showStackVal doc2raw (ex^.showDir) (ex^.context) x+) (format s t)
      format ('%':'g':s) (x:t) = first (showStackVal doc2svg (ex^.showDir) (ex^.context) x+) (format s t)
      format ('%':'l':s) (x:t) = first (showStackVal doc2latex (ex^.showDir) (ex^.context) x+) (format s t)
      format (c:s) t = first (fromString [c]+) (format s t)
      format "" t = ("",t)
  runStackState $ modify $ \case
    StackSymbol s:t -> uncurry ((:) . StackSymbol) (format (toString s) t)
    st -> st

runCOCBuiltin (COCB_Open (ReadImpl getResource)) = do
  s <- runStackState get
  case s of
    StackSymbol f:t -> do
      runStackState $ put t
      xs <- liftSubIO (getResource (f+".md")) >>= maybe undefined return . matches Just literate . (const "" <|> toString)
      execSymbolOrComment (Right "{") >> traverse_ execSymbolOrComment xs >> execSymbolOrComment (Right "}")
    _ -> return ()
                     
runCOCBuiltin COCB_ToInt = runStackState $ modify $ \case
  StackSymbol s:t -> StackInt (read (toString s)):t
  st -> st
runCOCBuiltin COCB_Concat = runStackState $ modify $ \case
  StackSymbol s:StackSymbol s':t -> StackSymbol (s'+s):t
  st -> st

runCOCBuiltin COCB_Uni = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackInt u:t | Just x <- runInContext ctx (mkUniverse u) -> StackCOC (COCExpr x):t
    st -> st
runCOCBuiltin COCB_Var = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackSymbol name:t | Just e <- runInContext (map (\(x,(_,v)) -> (x,v)) $ freshContext ctx) (mkVariable name) -> StackCOC (COCExpr e):t
    st -> st
runCOCBuiltin COCB_Ap = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    (StackCOC (COCExpr f):StackCOC (COCExpr x):t)
      | Just e <- runInContext ctx (mkApply f x) -> StackCOC (COCExpr e):t
    x -> x
runCOCBuiltin (COCB_Bind close bt) = do
  ctx <- runExtraState (getl context) 
  let dctx = length ctx
      setVal (StackCOC (COCExpr e@(ContextTerm d _)))
        | d==dctx || not close
        , Just e' <- runInContext ctx (mkBind bt e) = StackCOC (COCExpr e')
      setVal (StackDict dict) = StackDict (map setVal dict)
      setVal (StackList l) = StackList (map setVal l)
      setVal x = x
      setStack (x:t) = setVal x:if close then setStack t else t
      setStack [] = []
                                                         
  ctx' <- runStackState $ id <~ map (,if close && nonempty ctx then tail ctx else ctx) setStack
  runDictState $ modify $ map setVal
  runExtraState (context =- ctx')
runCOCBuiltin COCB_Mu = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackCOC (COCExpr e):t | Just e' <- runInContext ctx (mkMu e) -> StackCOC (COCExpr e'):t
                           | otherwise -> StackCOC COCNull:t
    st -> st


runCOCBuiltin COCB_MatchTerm = do
  st <- runStackState get
  cctx <- runExtraState (getl context)
  let tailCall v go = go >> execValue runCOCBuiltin (const unit) v
      runMatch onUniverse onLambda onProduct onApply onMu onVar onAxiom d e st' =
        case e of
          Bind Lambda x tx e' -> tailCall onLambda $ do
            runExtraState $ context =~ ((x,tx):)
            runStackState $ put (StackCOC (COCExpr (ContextTerm (d+1) (Cons (Ap (Sym 0) []))))
                                 :StackCOC (COCExpr (ContextTerm (d+1) e'))
                                 :st')
          Bind Prod x tx e' -> tailCall onProduct $ do
            runExtraState $ context =~ ((x,tx):)
            runStackState $ put (StackCOC (COCExpr (ContextTerm (d+1) (Cons (Ap (Sym 0) []))))
                                 :StackCOC (COCExpr (ContextTerm (d+1) e'))
                                 :st')
          Cons (Ap h []) -> do
            case h of
              Sym i | (x,_):_ <- takeLast (d-i) cctx -> tailCall onVar $ runStackState $ put (StackSymbol x:st')
                    | otherwise -> tailCall onVar $ runStackState $ put (StackSymbol ("#"+fromString (show i)):st')
              Mu ctx _ a -> do
                let a' = foldl' (\e' (x,tx,_) -> Bind Lambda x tx e') (Cons a) ctx
                tailCall onMu $ runStackState $ put (StackCOC (COCExpr (ContextTerm d a'))
                                                     :st')
              Axiom t a -> tailCall onAxiom $ do
                runStackState $ put (StackSymbol a
                                     :StackCOC (COCExpr (ContextTerm 0 t))
                                     :st')
          Cons (Ap h args) -> tailCall onApply $ do
            runStackState $ put (StackList (map (StackCOC . COCExpr . ContextTerm d) args)
                                 :StackCOC (COCExpr (ContextTerm d (Cons (Ap h []))))
                                 :st')
          Universe n -> tailCall onUniverse $ runStackState $ put (StackInt n:st')

  case st of
    StackList [onUniverse,onLambda,onProduct,onApply,onMu,onVar,onAxiom]:StackCOC (COCExpr (ContextTerm d e)):st' -> runMatch onUniverse onLambda onProduct onApply onMu onVar onAxiom d e st'
    onUniverse:onLambda:onProduct:onApply:onMu:onVar:onAxiom:StackCOC (COCExpr (ContextTerm d e)):st' -> runMatch onUniverse onLambda onProduct onApply onMu onVar onAxiom d e st'
    _ -> unit

runCOCBuiltin COCB_TypeOf = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackCOC (COCExpr e):t | Just e' <- runInContext ctx (checkType e) -> StackCOC (COCExpr e'):t
                           | otherwise -> StackCOC COCNull:t
    st -> st
runCOCBuiltin COCB_Convertible = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackCOC (COCExpr e):StackCOC (COCExpr e'):t ->
      StackCOC (COCConvertible (runInContext ctx $ conversionDelta e e')):t
    st -> st

runCOCBuiltin COCB_Pull = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackCOC (COCExpr e):st | Just e' <- runInContext ctx (pullTerm Nothing e) -> StackCOC (COCExpr e'):st
                            | otherwise -> StackCOC COCNull:st
    StackSymbol s:StackCOC (COCExpr e):st
      | Just e' <- runInContext ctx (pullTerm (Just s) e) -> StackCOC (COCExpr e'):st
      | otherwise -> StackCOC COCNull:st
    st -> st

runCOCBuiltin (COCB_Redirect (WriteImpl writeResource)) = do
  st <- runStackState get
  case st of
    StackSymbol f:StackProg p:t -> do
      runStackState $ put t
      oldH <- runExtraState (outputText <~ \x -> (id,x))
      execProgram runCOCBuiltin outputComment p
      newH <- runExtraState (outputText <~ \x -> (oldH,x))
      liftSubIO $ writeResource f (newH "")
    _ -> return ()

runCOCBuiltin (COCB_Cache (ReadImpl getResource) (WriteImpl writeResource)) = do
  st <- runStackState get
  case st of
    StackSymbol f:StackProg p:t -> do
      runStackState (put t)
      liftSubIO (getResource (f+".blob")) >>= \case
        Right res | Just v <- matches Just datum res -> runStackState $ modify $ (v:)
        _ -> do
          execProgram runCOCBuiltin outputComment p
          st' <- runStackState get
          case st' of
            v:_ -> liftSubIO $ writeResource (f+".blob") (serialize v)
            _ -> unit
    _ -> pushError "Invalid argument types for builtin 'cache'. Usage: <prog> <string> cache."

runCOCBuiltin COCB_Intro = do
  ctx <- runExtraState (getl context)
  s <- runStackState $ id <~ \case
    StackCOC (COCExpr e):t -> (t,runInContext ctx (insertHypBefore Nothing "_" e))
    StackSymbol name:StackCOC (COCExpr e):t
      -> (t,runInContext ctx (insertHypBefore Nothing name e))
    StackSymbol limit:StackSymbol name:StackCOC (COCExpr e):t
      -> (t,runInContext ctx (insertHypBefore (Just limit) name e))
    st -> (st,Nothing)
  modifyCOCEnv s
  
runCOCBuiltin COCB_Subst = do
  ctx <- runExtraState (getl context)
  s <- runStackState $ id <~ \case
    StackSymbol h:StackCOC (COCExpr e):t -> (t,runInContext ctx (substHyp h e))
    st -> (st,Nothing)
  modifyCOCEnv s

runCOCBuiltin COCB_Rename = do
  ctx <- runExtraState (getl context)
  ctx' <- runStackState $ id <~ \case
    StackSymbol s:StackSymbol s':t -> (t,map (\(n',(n,v)) -> (if n'==s then s' else n, v)) (freshContext ctx))
    st -> (st,ctx)
  runExtraState (context =- ctx')
runCOCBuiltin COCB_ContextVars = do
  ctx <- runExtraState (getl context)
  runStackState $ modify (StackList (map (StackSymbol . fst) (freshContext ctx)):)

runCOCBuiltin COCB_Extract = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    StackCOC (COCExpr (ContextTerm d e)):t -> StackCOC (COCAlgebraic (fromTerm e ([],takeLast d ctx))):t
    st -> st

runCOCBuiltin COCB_GetShowDir = do
  dir <- runExtraState (getl showDir)
  runStackState $ modify $ (StackCOC (COCDir (map (\(c,l) -> (c,StackSymbol (intercalate " " $ map (id <|> head . flip drop c) l))) dir)):)
runCOCBuiltin COCB_SetShowDir = do
  mod' <- runStackState $ id <~ \case
    StackCOC (COCDir d):t -> (t,showDir =- map (\(c,StackSymbol ws) -> (c,[case select ((==w) . fst) (zip c [0..]) of
                                                                                        (_,i):_ -> Right i
                                                                                        _ -> Left w
                                                                                     | w <- map fromString $ words (toString ws)])) d)
    st -> (st,return ())
  runExtraState mod'
runCOCBuiltin COCB_InsertNodeDir = do
  ctx <- runExtraState (getl context)
  runStackState $ modify $ \case
    x:StackCOC (COCExpr (ContextTerm d e)):StackCOC (COCDir dir):t ->
      StackCOC (COCDir (insert e (map fst (takeLast d ctx),x) dir)):t
    st -> st

runCOCBuiltin COCB_Render = runStackState $ modify $ \case
  StackProg p:st -> StackProg (foldMap renderStep p):st
  st -> st
  where renderStep (VerbStep v) = [VerbStep v]
        renderStep (ExecStep x) = [ExecStep x]
        renderStep (ConstStep c) = [ConstStep c]
        renderStep (CommentStep c) = renderComment c
        renderStep (ClosureStep closed cl) = [ClosureStep closed (renderClos cl)]
        renderClos (StackClosure act ps pt) = StackClosure act [(foldMap renderStep p,renderClos cl)
                                                               | (p,cl) <- ps] (foldMap renderStep pt)

renderComment (TextComment s) = [ConstStep (StackSymbol s), VerbStep "comment"]
renderComment (BeginCodeParagraph l code exs) = [ConstStep (StackInt l),ConstStep (StackSymbol code),ConstStep (StackList (map StackSymbol exs)), VerbStep "begin-code-paragraph"]
renderComment EndCodeParagraph = [VerbStep "end-code-paragraph"]
renderComment (BeginCodeSpan s) = [ConstStep (StackSymbol s),VerbStep "begin-code-span"]
renderComment (EndCodeSpan s) = [ConstStep (StackSymbol s),VerbStep "end-code-span"]

cocDict :: forall io str. IsCapriconString str => str -> (str -> io (String :+: str)) -> (str -> io (String :+: [Word8])) -> (str -> str -> io ()) -> (str -> [Word8] -> io ()) -> COCDict io str
cocDict version getResource getBResource writeResource writeBResource =
  mkDict ((".",StackProg []):("steps.",StackProg []):("mustache.",StackProg []):("version",StackSymbol version):
           [(x,StackBuiltin b) | (x,b) <- [
               ("def"                     , Builtin_Def                           ),
               ("$"                       , Builtin_DeRef                         ),
               ("lookup"                  , Builtin_Lookup                        ),
               ("exec"                    , Builtin_Exec                          ),
               ("quote"                   , Builtin_Quote                         ),
               ("vocabulary"              , Builtin_CurrentDict                   ),
               ("set-vocabulary"          , Builtin_SetCurrentDict                ),

               ("stack"                   , Builtin_Stack                         ),
               ("set-stack"               , Builtin_SetStack                      ),
               ("clear"                   , Builtin_Clear                         ),
               ("shift"                   , Builtin_Shift                         ),
               ("shaft"                   , Builtin_Shaft                         ),
               ("pop"                     , Builtin_Pop                           ),
               ("popn"                    , Builtin_PopN                          ),
               ("dup"                     , Builtin_Dup                           ),
               ("dupn"                    , Builtin_DupN                          ),
               ("swap"                    , Builtin_Swap                          ),
               ("swapn"                   , Builtin_SwapN                         ),
               ("pick"                    , Builtin_Pick                          ),
               ("pre-render"              , Builtin_Extra COCB_Render             ),

               ("["                       , Builtin_ListBegin                     ),
               ("]"                       , Builtin_ListEnd                       ),
               
               ("io/exit"                 , Builtin_Extra COCB_Quit               ),
               ("io/print"                , Builtin_Extra COCB_Print              ),
               ("io/source"               , Builtin_Extra (COCB_Open (ReadImpl getResource))), 
               ("io/cache"                , Builtin_Extra (COCB_Cache (ReadImpl getBResource) (WriteImpl writeBResource))),
               ("io/redirect"             , Builtin_Extra (COCB_Redirect (WriteImpl writeResource))),
  
               ("string/format"           , Builtin_Extra COCB_Format             ),
               ("string/to-int"           , Builtin_Extra COCB_ToInt              ),
               
               ("arith/+"                 , Builtin_Add                           ),
               ("arith/-"                 , Builtin_Sub                           ),
               ("arith/*"                 , Builtin_Mul                           ),
               ("arith/div"               , Builtin_Div                           ),
               ("arith/mod"               , Builtin_Mod                           ),
               ("arith/sign"              , Builtin_Sign                          ),
               
               ("list/each"               , Builtin_Each                          ),
               ("list/range"              , Builtin_Range                         ),
               ("list/cons"               , Builtin_Cons                          ),

               ("dict/empty"              , Builtin_Empty                         ),
               ("dict/insert"             , Builtin_Insert                        ),
               ("dict/delete"             , Builtin_Delete                        ),
               ("dict/keys"               , Builtin_Keys                          ),
               
               ("term-index/pattern-index"     , Builtin_Extra COCB_GetShowDir         ),
               ("term-index/set-pattern-index" , Builtin_Extra COCB_SetShowDir         ),
               ("term-index/index-insert"      , Builtin_Extra COCB_InsertNodeDir      ),
               
               ("construction/universe"            , Builtin_Extra COCB_Uni                ),
               ("construction/variable"            , Builtin_Extra COCB_Var                ),
               ("construction/apply"               , Builtin_Extra COCB_Ap                 ),
               ("construction/lambda"              , Builtin_Extra (COCB_Bind False Lambda)),
               ("construction/forall"              , Builtin_Extra (COCB_Bind False Prod  )),
               ("construction/mu"                  , Builtin_Extra COCB_Mu                 ),
               ("construction/axiom"               , Builtin_Extra COCB_Axiom              ),
               ("construction/pull"                , Builtin_Extra COCB_Pull               ),
               
               ("query/convertible"         , Builtin_Extra COCB_Convertible        ),
               ("query/extract"             , Builtin_Extra COCB_Extract            ),
               ("query/match"               , Builtin_Extra COCB_MatchTerm          ),
               ("query/type"                , Builtin_Extra COCB_TypeOf             ),
               
               ("context/intro"           , Builtin_Extra COCB_Intro                ),
               ("context/extro-lambda"    , Builtin_Extra (COCB_Bind True Lambda )),
               ("context/extro-forall"    , Builtin_Extra (COCB_Bind True Prod   )),
               ("context/rename"          , Builtin_Extra COCB_Rename             ),
               ("context/substitute"      , Builtin_Extra COCB_Subst              ),
               ("context/hypotheses"      , Builtin_Extra COCB_ContextVars        )
               ]])
  where mkDict :: [(str,StackVal str (COCBuiltin io str) (COCValue io str))] -> Map str (StackVal str (COCBuiltin io str) (COCValue io str))
        mkDict = foldr addElt (c'map zero)
        addElt (x,v) = atP (first fromString $ splitPath $ toString x) %- Just v
        splitPath ('/':x) = ("",uncurry (:) (first fromString $ splitPath x))
        splitPath (h:t) = let ~(w,l) = splitPath t in (h:w,l)
        splitPath [] = ("",[])
        atP (h,[]) = at h
        atP (h,x:t) = at h.l'Just (StackDict zero).t'StackDict.atP (x,t)

outputComment :: forall str io m.
                 (MonadSubIO io m,IsCapriconString str,
                  MonadStack (COCState str) str (COCBuiltin io str) (COCValue io str) m,
                  IOListFormat io str,ListFormat str) =>
                 StackComment str -> m ()
outputComment c = execProgram runCOCBuiltin (\_ -> unit) (renderComment c)

markSyntax str = fold [if isWord then
                          let qw = htmlQuote w
                              withSpans | w=="{" = \x -> "<span class=\"quote quote-brace\">"+x
                                        | w==",{" = \x -> "<span class=\"quote quote-splice\">"+x
                                        | w=="${" = \x -> "<span class=\"quote quote-exec\">"+x
                                        | w=="}" = \x -> x+"</span>"
                                        | otherwise = \x -> x
                          in withSpans ("<span class=\"symbol\" data-symbol-name=\""+qw+"\">"+qw+"</span>")
                        else w
                      | (isWord,w) <- stringWordsAndSpaces False str]
