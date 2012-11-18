{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}

-- | Vector conversions and utilities.

module System.IO.Streams.Vector
 ( -- * Vector conversions
   fromVector
 , toVector
 , outputToVector
 , toMutableVector
 , outputToMutableVector
 , writeVector

   -- * Utility
 , chunkVector
 , vectorOutputStream
 , mutableVectorOutputStream
 ) where

------------------------------------------------------------------------------
import           Control.Concurrent.MVar           (modifyMVar, modifyMVar_,
                                                    newMVar)
import           Control.Monad                     ((>=>))
import           Control.Monad.IO.Class            (MonadIO (..))
import           Control.Monad.Primitive           (PrimState (..))
import qualified Data.Vector.Fusion.Stream         as VS
import qualified Data.Vector.Fusion.Stream.Monadic as SM
import           Data.Vector.Generic               (Vector (..))
import qualified Data.Vector.Generic               as V
import           Data.Vector.Generic.Mutable       as VM
import           System.IO.Streams.Internal        (InputStream, OutputStream,
                                                    Sink (..), fromGenerator,
                                                    nullSink, sinkToStream,
                                                    yield)
import qualified System.IO.Streams.Internal        as S


------------------------------------------------------------------------------
-- | Transforms a vector into an 'InputStream' that yields each of the values
-- in the vector in turn.
fromVector :: Vector v a => v a -> IO (InputStream a)
fromVector = fromGenerator . V.mapM_ yield
{-# INLINE fromVector #-}


------------------------------------------------------------------------------
-- | Drains an 'InputStream', converting it to a vector. N.B. that this
-- function reads the entire 'InputStream' strictly into memory and as such is
-- not recommended for streaming applications or where the size of the input is
-- not bounded or known.
toVector :: Vector v a => InputStream a -> IO (v a)
toVector = toMutableVector >=> V.basicUnsafeFreeze
{-# INLINE toVector #-}


------------------------------------------------------------------------------
-- | Drains an 'InputStream', converting it to a mutable vector. N.B. that this
-- function reads the entire 'InputStream' strictly into memory and as such is
-- not recommended for streaming applications or where the size of the input is
-- not bounded or known.
toMutableVector :: VM.MVector v a => InputStream a -> IO (v (PrimState IO) a)
toMutableVector input = VM.munstream $ SM.unfoldrM go ()
  where
    go !z = S.read input >>= maybe (return Nothing)
                                   (\x -> return $! Just (x, z))
{-# INLINE toMutableVector #-}


------------------------------------------------------------------------------
-- | 'vectorOutputStream' returns an 'OutputStream' which stores values fed
-- into it and an action which flushes all stored values to a vector.
--
-- The flush action resets the store.
--
-- Note that this function /will/ buffer any input sent to it on the heap.
-- Please don't use this unless you're sure that the amount of input provided
-- is bounded and will fit in memory without issues.
vectorOutputStream :: Vector v c => IO (OutputStream c, IO (v c))
vectorOutputStream = do
    (os, flush) <- mutableVectorOutputStream
    return $! (os, flush >>= V.basicUnsafeFreeze)
{-# INLINE vectorOutputStream #-}


------------------------------------------------------------------------------
-- | 'mutableVectorOutputStream' returns an 'OutputStream' which stores values
-- fed into it and an action which flushes all stored values to a vector.
--
-- The flush action resets the store.
--
-- Note that this function /will/ buffer any input sent to it on the heap.
-- Please don't use this unless you're sure that the amount of input provided
-- is bounded and will fit in memory without issues.
mutableVectorOutputStream :: VM.MVector v c =>
                             IO (OutputStream c, IO (v (PrimState IO) c))
mutableVectorOutputStream = do
    r <- newMVar SM.empty
    c <- sinkToStream $ consumer r
    return (c, flush r)

  where
    consumer r = go
      where
        go = Sink $ maybe (return nullSink)
                          (\c -> do
                               modifyMVar_ r $ return . SM.cons c
                               return go)
    flush r = modifyMVar r $ \str -> do
                                v <- VM.munstreamR str
                                return $! (SM.empty, v)
{-# INLINE mutableVectorOutputStream #-}


------------------------------------------------------------------------------
-- | Given an IO action that requires an 'OutputStream', creates one and
-- captures all the output the action sends to it as a mutable vector.
--
-- Example:
--
-- @
-- ghci> import "Control.Applicative"
-- ghci> import qualified "Data.Vector" as V
-- ghci> (('connect' <$> 'System.IO.Streams.fromList' [1, 2, 3::'Int'])
--        >>= 'outputToMutableVector'
--        >>= V.'Data.Vector.freeze'
-- fromList [1,2,3]
-- @
outputToMutableVector :: MVector v a =>
                         (OutputStream a -> IO b)
                      -> IO (v (PrimState IO) a)
outputToMutableVector f = do
    (os, getVec) <- mutableVectorOutputStream
    _ <- f os
    getVec
{-# INLINE outputToMutableVector #-}


------------------------------------------------------------------------------
-- | Given an IO action that requires an 'OutputStream', creates one and
-- captures all the output the action sends to it as a vector.
--
-- Example:
--
-- @
-- ghci> import "Control.Applicative"
-- ghci> (('connect' <$> 'System.IO.Streams.fromList' [1, 2, 3]) >>= 'outputToVector')
--           :: IO ('Data.Vector.Vector' Int)
-- fromList [1,2,3]
-- @
outputToVector :: Vector v a => (OutputStream a -> IO b) -> IO (v a)
outputToVector = outputToMutableVector >=> V.basicUnsafeFreeze
{-# INLINE outputToVector #-}


------------------------------------------------------------------------------
-- | Splits an input stream into chunks of at most size @n@.
--
-- Example:
--
-- @
-- ghci> ('System.IO.Streams.fromList' [1..14::Int] >>= 'chunkVector' 4 >>= 'System.IO.Streams.toList')
--          :: IO ['Data.Vector.Vector' Int]
-- [fromList [1,2,3,4],fromList [5,6,7,8],fromList [9,10,11,12],fromList [13,14]]
-- @
chunkVector :: Vector v a => Int -> InputStream a -> IO (InputStream (v a))
chunkVector n input = fromGenerator $ go n VS.empty
  where
    go !k !str | k <= 0    = yield (V.unstreamR str) >> go n VS.empty
               | otherwise = do
                     liftIO (S.read input) >>= maybe finish chunk
      where
        finish = let v = V.unstreamR str
                 in if V.null v then return $! () else yield v
        chunk x = go (k - 1) (VS.cons x str)
{-# INLINE chunkVector #-}


------------------------------------------------------------------------------
-- | Feeds a vector to an 'OutputStream'. Does /not/ write an end-of-stream to
-- the stream.
writeVector :: Vector v a => v a -> OutputStream a -> IO ()
writeVector v out = V.mapM_ (flip S.write out . Just) v
{-# INLINE writeVector #-}
