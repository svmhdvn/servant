{-# LANGUAGE DeriveDataTypeable       #-}
{-# LANGUAGE DeriveGeneric            #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE KindSignatures           #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE PolyKinds                #-}
{-# LANGUAGE TupleSections            #-}
{-# OPTIONS_HADDOCK not-home          #-}

module Servant.API.Stream where

import           Control.Arrow               ((***), first)
import           Data.ByteString.Lazy        (ByteString, empty)
import qualified Data.ByteString.Lazy.Char8  as LB
import           Data.Proxy                  (Proxy)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           Text.Read                   (readMaybe)

-- | A stream endpoint for a given method emits a stream of encoded values at a given Content-Type, delimited by a framing strategy.
data Stream (method :: k1) (framing :: *) (contentType :: *) a
  deriving (Typeable, Generic)

-- | Stream endpoints may be implemented as producing a @StreamGenerator@ -- a function that itself takes two emit functions -- the first to be used on the first value the stream emits, and the second to be used on all subsequent values (to allow interspersed framing strategies such as comma separation).
newtype StreamGenerator a =  StreamGenerator {getStreamGenerator :: (a -> IO ()) -> (a -> IO ()) -> IO ()}

-- | ToStreamGenerator is intended to be implemented for types such as Conduit, Pipe, etc. By implementing this class, all such streaming abstractions can be used directly as endpoints.
class ToStreamGenerator f a where
   toStreamGenerator :: f a -> StreamGenerator a

instance ToStreamGenerator StreamGenerator a
   where toStreamGenerator x = x

-- | The FramingRender class provides the logic for emitting a framing strategy. The strategy emits a header, followed by boundary-delimited data, and finally a termination character. For many strategies, some of these will just be empty bytestrings.
class FramingRender strategy a where
   header    :: Proxy strategy -> Proxy a -> ByteString
   boundary  :: Proxy strategy -> Proxy a -> BoundaryStrategy
   terminate :: Proxy strategy -> Proxy a -> ByteString

-- | The bracketing strategy generates things to precede and follow the content, as with netstrings.
--   The intersperse strategy inserts seperators between things, as with newline framing.
--   Finally, the general strategy performs an arbitrary rewrite on the content, to allow escaping rules and such.
data BoundaryStrategy = BoundaryStrategyBracket (ByteString -> (ByteString,ByteString))
                      | BoundaryStrategyIntersperse ByteString
                      | BoundaryStrategyGeneral (ByteString -> ByteString)

-- | The FramingUnrender class provides the logic for parsing a framing strategy. Given a ByteString, it strips the header, and returns a tuple of the remainder along with a step function that can progressively "uncons" elements from this remainder. The error state is presented per-frame so that protocols that can resume after errors are able to do so.

class FramingUnrender strategy a where
   unrenderFrames :: Proxy strategy -> Proxy a -> ByteString -> (ByteString,  ByteString -> (Either String ByteString, ByteString))

-- | A simple framing strategy that has no header or termination, and inserts a newline character between each frame.
--   This assumes that it is used with a Content-Type that encodes without newlines (e.g. JSON).
data NewlineFraming

instance FramingRender NewlineFraming a where
   header    _ _ = empty
   boundary  _ _ = BoundaryStrategyIntersperse "\n"
   terminate _ _ = empty

instance FramingUnrender NewlineFraming a where
   unrenderFrames _ _ = (, (Right *** LB.drop 1) . LB.break (== '\n'))

-- | The netstring framing strategy as defined by djb: <http://cr.yp.to/proto/netstrings.txt>
data NetstringFraming

instance FramingRender NetstringFraming a where
   header    _ _ = empty
   boundary  _ _ = BoundaryStrategyBracket $ \b -> (LB.pack . show . LB.length $ b, "")
   terminate _ _ = empty

instance FramingUnrender NetstringFraming a where
   unrenderFrames _ _ = (, \b -> let (i,r) = LB.break (==':') b
                                 in case readMaybe (LB.unpack i) of
                                    Just len -> first Right $ LB.splitAt len . LB.drop 1 $ r
                                    Nothing -> (Left ("Bad netstring frame, couldn't parse value as integer value: " ++ LB.unpack i), LB.drop 1 . LB.dropWhile (/= ',') $ r)
                        )
