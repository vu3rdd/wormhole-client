module Transit.Internal.Pipeline
  ( sendPipeline
  , receivePipeline
  )
where

import Protolude

import Crypto.Hash (SHA256(..))
import Data.Conduit ((.|))
import Data.ByteString.Builder(toLazyByteString, word32BE)
import Data.Binary.Get (getWord32be, runGet)
import Crypto.Saltine.Internal.ByteSizes (boxNonce)
import System.FilePath ((</>))

import qualified Crypto.Hash as Hash
import qualified Conduit as C
import qualified Data.Conduit.Network as CN
import qualified Data.Binary.Builder as BB
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Crypto.Saltine.Core.SecretBox as SecretBox
import qualified Crypto.Saltine.Class as Saltine

import Transit.Internal.Network
import Transit.Internal.Crypto

sendPipeline :: C.MonadResource m =>
                FilePath
             -> TCPEndpoint
             -> SecretBox.Key
             -> C.ConduitM a c m (Text, ())
sendPipeline fp (TCPEndpoint s) key =
  C.sourceFile fp .| sha256PassThroughC `C.fuseBoth` (encryptC key .| CN.sinkSocket s)

receivePipeline :: C.MonadResource m =>
                   FilePath
                -> Int
                -> TCPEndpoint
                -> SecretBox.Key
                -> C.ConduitM a c m (Text, ())
receivePipeline fp len (TCPEndpoint s) key =
    CN.sourceSocket s
    .| assembleRecordC
    .| decryptC key
    .| passThroughBytesC len
    .| sha256PassThroughC `C.fuseBoth` C.sinkFileCautious ("./" </> fp)

encryptC :: Monad m => SecretBox.Key -> C.ConduitT ByteString ByteString m ()
encryptC key = go Saltine.zero
  where
    go nonce = do
      b <- C.await
      case b of
        Nothing -> return ()
        Just chunk -> do
          let cipherText = encrypt key nonce chunk
              cipherTextSize = toLazyByteString (word32BE (fromIntegral (BS.length cipherText)))
          C.yield (toS cipherTextSize)
          C.yield cipherText
          go (Saltine.nudge nonce)

decryptC :: MonadIO m => SecretBox.Key -> C.ConduitT ByteString ByteString m ()
decryptC key = loop
  where
    loop = do
      b <- C.await
      case b of
        Nothing -> return ()
        Just bs -> do
          let (nonceBytes, ciphertext) = BS.splitAt boxNonce bs
              nonce = fromMaybe (panic "unable to decode nonce") $
                Saltine.decode nonceBytes
              maybePlainText = SecretBox.secretboxOpen key nonce ciphertext
          case maybePlainText of
            Just plaintext -> do
              C.yield plaintext
              loop
            Nothing -> throwIO (CouldNotDecrypt "SecretBox failed to open")

sha256PassThroughC :: (Monad m) => C.ConduitT ByteString ByteString m Text
sha256PassThroughC = go $! Hash.hashInitWith SHA256
  where
    go :: (Monad m) => Hash.Context SHA256 -> C.ConduitT ByteString ByteString m Text
    go ctx = do
      b <- C.await
      case b of
        Nothing -> return $! show (Hash.hashFinalize ctx)
        Just bs -> do
          C.yield bs
          go $! Hash.hashUpdate ctx bs

assembleRecordC :: Monad m => C.ConduitT ByteString ByteString m ()
assembleRecordC = do
  b <- C.await
  case b of
    Nothing -> return ()
    Just bs -> do
      let (hdr, pkt) = BS.splitAt 4 bs
      let len = runGet getWord32be (BL.fromStrict hdr)
      getChunk (fromIntegral len - BS.length pkt) (BB.fromByteString pkt)
  where
    getChunk :: Monad m => Int -> BB.Builder -> C.ConduitT ByteString ByteString m ()
    getChunk size res = do
      b <- C.await
      case b of
        Nothing -> return ()
        Just bs | size == BS.length bs -> do
                    C.yield $! toS (BB.toLazyByteString res) <> bs
                    assembleRecordC
                | size < BS.length bs -> do
                    let (f, l) = BS.splitAt size bs
                    C.leftover l
                    C.yield (toS (BB.toLazyByteString res) <> f)
                    assembleRecordC
                | otherwise ->
                    getChunk (size - BS.length bs) (res <> BB.fromByteString bs)

-- | pass only @n@ bytes through the conduit and then terminate the pipeline.
passThroughBytesC :: Monad m => Int -> C.ConduitT ByteString ByteString m ()
passThroughBytesC n | n <= 0 = return ()
                    | otherwise = do
                        b <- C.await
                        case b of
                          Nothing -> return ()
                          Just bs -> do
                            C.yield bs
                            passThroughBytesC (n - BS.length bs)
