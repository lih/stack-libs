{-# LANGUAGE DeriveGeneric #-}
module Curly.Core.VCS.Diff where

import Definitive
import Language.Format

data Patch k a = Patch [k] [(k,a)]
               deriving (Generic,Eq,Ord,Show)
instance (Serializable Bytes k,Serializable Bytes a) => Serializable Bytes (Patch k a)
instance (Format Bytes a,Format Bytes k) => Format Bytes (Patch k a)

diff :: Ord k => Map k a -> Map k a -> Patch k a
diff m' m = Patch (keys deleted) (inserted^.ascList)
  where inter = zipWith const m' m
        deleted = m' - inter
        inserted = m - inter

patch :: Ord k => Patch k a -> Map k a -> Map k a
patch (Patch del ins) m = composing (uncurry insert) ins (composing delete del m)
