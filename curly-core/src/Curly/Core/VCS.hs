{-# LANGUAGE DeriveGeneric, ExistentialQuantification, KindSignatures, UndecidableInstances #-}
module Curly.Core.VCS where

import Curly.Core
import Curly.Core.Library
import Curly.Core.VCS.Diff
import Curly.Core.Security
import Definitive
import Language.Format
import qualified Crypto.Hash.SHA256 as SHA256
import System.Process (readProcess, withCreateProcess)
import qualified System.Process as Sys
import Data.IORef

newtype Hash = Hash Chunk
             deriving (Eq,Ord)
hashData :: Bytes -> Hash
hashData b = Hash (SHA256.hashlazy b)
instance Show Hash where
  show (Hash h) = show (B64Chunk h)
instance Read Hash where
  readsPrec _ = readsParser (readable <&> \(B64Chunk h) -> Hash h)
instance Serializable Hash where
  encode (Hash h) = h^.chunkBuilder
instance Format Hash where
  datum = Hash<$>getChunk 32

commitHash :: Commit -> Hash
commitHash c = hashData (serialize c)

type Commit = Compressed (Patch LibraryID Metadata,Maybe Hash)
type Branches = Map String ((PublicKey,String):+:Hash)
data VCKey o = LibraryKey LibraryID (WithResponse Bytes)
             | AdditionalKey LibraryID String (WithResponse (Signed (String,Bytes)))
             | BranchesKey PublicKey (WithResponse (Signed Branches))
             | CommitKey Hash (WithResponse Commit)
             | OtherKey o
           deriving (Show,Generic)
instance Serializable o => Serializable (VCKey o)
instance Format o => Format (VCKey o)
instance Serializable o => Eq (VCKey o) where a==b = compare a b==EQ
instance Serializable o => Ord (VCKey o) where compare = comparing serialize
instance Functor VCKey where
  map f (OtherKey o) = OtherKey (f o)
  map f (LibraryKey a b) = LibraryKey a b
  map f (AdditionalKey a b c) = AdditionalKey a b c
  map f (CommitKey a b) = CommitKey a b
  map f (BranchesKey a b) = BranchesKey a b

class MonadIO vc => MonadVC vc s | vc -> s where
  vcStore :: Serializable a => s -> (WithResponse a -> VCKey ()) -> a -> vc ()
  vcLoad :: Format a => s -> (WithResponse a -> VCKey ()) -> vc (Maybe a)
  runVC :: vc a -> IO a

keyName k = show (B64Chunk (serialize (k WithResponse :: VCKey ())^.chunk))

newtype Dummy_VC a = Dummy_VC (IO a)
                   deriving (Functor,SemiApplicative,Unit,Applicative)
instance Monad Dummy_VC where join = coerceJoin Dummy_VC
instance MonadIO Dummy_VC where liftIO = Dummy_VC
instance MonadVC Dummy_VC () where
  vcStore _ _ _ = Dummy_VC unit
  vcLoad _ _ = Dummy_VC (return Nothing)
  runVC (Dummy_VC x) = x

newtype File_VC a = File_VC (IO a)
                  deriving (Functor,SemiApplicative,Unit,Applicative)
instance Monad File_VC where join = coerceJoin File_VC
instance MonadIO File_VC where liftIO = File_VC
instance MonadVC File_VC String where
  vcStore base k v = liftIO $ do
    let f = cacheFileName base (keyName k) "blob"
    createFileDirectory f
    writeSerial f v
  vcLoad base k = liftIO $ do
    try (return Nothing) (Just <$> readFormat (cacheFileName base (keyName k) "blob"))
  runVC (File_VC io) = io

vcsProtoRoots :: IORef [FilePath]
vcsProtoRoots = newIORef []^.thunk
newtype Proto_VC a = Proto_VC (IO a)
                     deriving (Functor,SemiApplicative,Unit,Applicative)
instance Monad Proto_VC where join = coerceJoin Proto_VC
instance MonadIO Proto_VC where liftIO = Proto_VC
instance MonadVC Proto_VC (String,String) where
  vcStore (proto,path) k v = liftIO $ do
    foldr (\dir tryNext ->
            try tryNext
            $ withCreateProcess (Sys.proc "sh" [dir+"/"+proto,"put",path,keyName k]) { Sys.std_in = Sys.CreatePipe }
            $ \(Just i) _ _ _ -> writeHSerial i v)
      unit =<< readIORef vcsProtoRoots
    
  vcLoad (proto,path) k = liftIO $ do
    foldr (\dir tryNext ->
            try tryNext
            $ withCreateProcess (Sys.proc "sh" [dir+"/"+proto,"get",path,keyName k]) { Sys.std_out = Sys.CreatePipe }
            $ \_ (Just o) _ _ -> try (return Nothing) (Just <$> readHFormat o))
      (return Nothing) =<< readIORef vcsProtoRoots
  runVC (Proto_VC io) = io

newtype Client_VC a = Client_VC (IO a)
                  deriving (Functor,SemiApplicative,Unit,Applicative)
instance Monad Client_VC where join = coerceJoin Client_VC
instance MonadIO Client_VC where liftIO = Client_VC
instance MonadVC Client_VC Handle where
  vcStore conn k l = liftIO $ writeHSerial conn ((True,k WithResponse),l)
  vcLoad conn k = liftIO $ try (return Nothing) $ runConnection Just False conn $ do
    exchange (\r -> (False,k (pMaybe r))) >>= maybe zero pure
  runVC (Client_VC io) = io

newtype Combined_VC vc1 vc2 a = Combined_VC ((vc1 :.: vc2) a)
                              deriving (Functor,SemiApplicative,Unit,Applicative)
combined_lift1 vc1 = Combined_VC (Compose (map return vc1))
instance (MonadVC vc1 _c1, MonadVC vc2 _c2) => Monad (Combined_VC vc1 vc2) where
  join (Combined_VC (Compose vc1212)) = Combined_VC $ Compose $ liftIO $ do
    vc121 <- runVC vc1212
    Combined_VC (Compose vc12) <- runVC vc121
    runVC vc12
instance (MonadVC vc1 _c1) => MonadTrans (Combined_VC vc1) where
  lift vc2 = Combined_VC (Compose $ return vc2)
instance (MonadVC vc1 conn1, MonadVC vc2 conn2) => MonadVC (Combined_VC vc1 vc2) (conn1,conn2) where
  vcStore (c1,c2) k v = do combined_lift1 (vcStore c1 k v); lift (vcStore c2 k v)
  vcLoad (c1,c2) k = do
    v1 <- combined_lift1 (vcLoad c1 k)
    case v1 of
      Just _ -> return v1
      _ -> lift (vcLoad c2 k)
  runVC (Combined_VC (Compose m)) = runVC m >>= runVC

pMaybe :: WithResponse (Maybe a) -> WithResponse a
pMaybe _ = WithResponse
maybeP :: WithResponse a -> WithResponse (Maybe a)
maybeP _ = WithResponse

vcServer (VCSB_Native _ st run) = do
  (b,k) <- receive
  logLine Verbose ("Received request "+show (b,k))
  if b then case k of
    LibraryKey lid _ -> receive >>= liftIO . run . vcStore st (LibraryKey lid)
    AdditionalKey lid nm _ ->  receive >>= liftIO . run . vcStore st (AdditionalKey lid nm)
    CommitKey h _ ->    receive >>= liftIO . run . vcStore st (CommitKey h)
    BranchesKey pub _ -> receive >>= liftIO . run . vcStore st (BranchesKey pub)
    OtherKey () -> return ()
    else case k of
    LibraryKey lid t -> sending (maybeP t) =<< liftIO (run $ vcLoad st (LibraryKey lid))
    AdditionalKey lid nm t -> sending (maybeP t) =<< liftIO (run $ vcLoad st (AdditionalKey lid nm))
    CommitKey h t -> sending (maybeP t) =<< liftIO (run $ vcLoad st (CommitKey h))
    BranchesKey pub t -> sending (maybeP t) =<< liftIO (run $ vcLoad st (BranchesKey pub))
    OtherKey () -> return ()

vcbStore :: (Serializable a,MonadIO m) => VCSBackend -> (WithResponse a -> VCKey ()) -> a -> m ()
vcbStore (VCSB_Native _ st run) k a = liftIO (run (vcStore st k a))
vcbLoad :: (Format a,MonadIO m) => VCSBackend -> (WithResponse a -> VCKey ()) -> m (Maybe a)
vcbLoad (VCSB_Native _ st run) k = liftIO (run (vcLoad st k))
vcbLoadP :: (Format a,MonadIO m) => VCSBackend -> (WithResponse a -> VCKey ()) -> ParserT s m a
vcbLoadP b k = vcbLoad b k >>= maybe zero return

data VCSBackend = forall m s. MonadVC m s => VCSB_Native String s (forall a. m a -> IO a)
instance Eq VCSBackend where a == b = compare a b == EQ
instance Ord VCSBackend where
  compare (VCSB_Native s _ _) (VCSB_Native s' _ _) = compare s s'
dummyBackend = VCSB_Native "dummy" () (\(Dummy_VC io) -> io)
nativeBackend :: MonadIO m => String -> PortNumber -> m VCSBackend
nativeBackend h p = do
  conn <- liftIO (connectTo h p)
  return (VCSB_Native ("curly-vc://"+h+":"+show p) conn (\(Client_VC io) -> io))
fileBackend p = VCSB_Native ("file://"+p) p (\(File_VC io) -> io)
protoBackend pr p = VCSB_Native (pr+"://"+p) (pr,p) (\(Proto_VC io) -> io)
instance Show VCSBackend where
  show (VCSB_Native s _ _) = s
instance Read VCSBackend where
  readsPrec _ = readsParser backend
    where backend = proto_native <+? proto_file <+? proto_arbitrary <+? fill dummyBackend (several "dummy")
          proto_native = do
            several "curly-vc://" <+? single '@'
            map (by thunk) $ liftA2 nativeBackend
              (many1' (noneOf ":") <&> \x -> if x=="_" then "127.0.0.1" else x)
              (option' 5402 (single ':' >> number))
          proto_file = do
            several "file://" <+? lookingAt (single '/')
            fileBackend <$> remaining
          proto_arbitrary = do
            proto <- many1' (satisfy (/=':'))
            several "://"
            protoBackend proto <$> remaining
              
curlyVCSBackend :: VCSBackend
curlyVCSBackend = fromMaybe (getDefaultVCS^.thunk) (matches Just readable (envVar "" "CURLY_VCS"))
  where getDefaultVCS = try (return dummyBackend) $ do
          lns <- map words . lines <$> readProcess "/usr/lib/curly/default-vcs" [] ""
          case lns of
            ([h,p]:_) -> nativeBackend h (fromInteger $ read p)
            _ -> return dummyBackend
            
curlyPublisher :: String
curlyPublisher = envVar "" "CURLY_PUBLISHER"

getVCSBranches :: MonadIO m => String -> m Branches
getVCSBranches name = do
  u <- lookup name <$> getKeyStore
  case (curlyVCSBackend,u) of
    (VCSB_Native _ st run,Just (_,pub,_,_,_)) -> liftIO $ do
      map (maybe zero unsafeExtractSigned) $ run $ vcLoad st (BranchesKey pub)
    _ -> return zero
