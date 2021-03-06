{-# LANGUAGE OverloadedStrings #-}
module Transit.Internal.Peer
  ( makeSenderHandshake
  , makeReceiverHandshake
  , makeRecordKeys
  , makeRelayHandshake
  , senderTransitExchange
  , senderOfferExchange
  , sendOffer
  , receiveOffer
  , sendMessageAck
  , receiveMessageAck
  , senderHandshakeExchange
  , receiverHandshakeExchange
  , sendTransitMsg
  , decodeTransitMsg
  , makeAckMessage
  , receiveWormholeMessage
  , sendWormholeMessage
  , generateTransitSide
  , InvalidHandshake(..)
  , sendRecord
  , receiveRecord
  , unzipInto
  )
where

import Protolude hiding ((<.>))

import qualified Control.Exception as E
import qualified Crypto.Saltine.Class as Saltine
import qualified Crypto.Saltine.Core.SecretBox as SecretBox
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as Set

import Data.Aeson (encode, eitherDecode)
import Data.Binary.Get (getWord32be, runGet)
import Data.ByteString.Builder(toLazyByteString, word32BE, byteString)
import Data.Bits (shiftL)
import Data.Hex (hex)
import Data.Text (toLower)
import System.Posix.Types (FileOffset, FileMode)
import System.PosixCompat.Files (getFileStatus, fileSize, fileMode, isDirectory)
import System.FilePath (takeFileName, takeBaseName, dropTrailingPathSeparator, (<.>), (</>))
import Crypto.Random (MonadRandom(..))
import Data.ByteArray.Encoding (convertToBase, Base(Base16))
import System.IO.Error (IOError)
import System.Directory.PathWalk (pathWalk)
import System.Directory (getTemporaryDirectory)
import System.IO.Temp (createTempDirectory)
import Codec.Archive.Zip ( createArchive
                         , withArchive
                         , CompressionMethod ( Deflate )
                         , mkEntrySelector
                         , unEntrySelector
                         , packDirRecur
                         , unpackInto
                         , forEntries
                         , setExternalFileAttrs)

import Transit.Internal.Messages
  ( TransitMsg(..)
  , TransitAck(..)
  , Ack( FileAck, MessageAck )
  , Ability(..)
  , AbilityV1(..)
  , ConnectionHint)
import Transit.Internal.Network
  ( TCPEndpoint(..)
  , sendBuffer
  , recvBuffer
  , CommunicationError(..))
import Transit.Internal.Crypto
  ( encrypt
  , decrypt
  , deriveKeyFromPurpose
  , Purpose(..)
  , PlainText(..)
  , CipherText(..)
  , CryptoError(..))

import qualified MagicWormhole

makeSenderHandshake :: SecretBox.Key -> ByteString
makeSenderHandshake key =
  (toS @Text @ByteString "transit sender ") <> hexid <> (toS @Text @ByteString " ready\n\n")
  where
    subkey = deriveKeyFromPurpose SenderHandshake key
    hexid = toS (toLower (toS @ByteString @Text (hex subkey)))

makeReceiverHandshake :: SecretBox.Key -> ByteString
makeReceiverHandshake key =
  (toS @Text @ByteString "transit receiver ") <> hexid <> (toS @Text @ByteString " ready\n\n")
  where
    subkey = deriveKeyFromPurpose ReceiverHandshake key
    hexid = toS (toLower (toS @ByteString @Text (hex subkey)))

-- | create relay handshake bytestring
-- "please relay HEXHEX for side XXXXX\n"
makeRelayHandshake :: SecretBox.Key -> MagicWormhole.Side -> ByteString
makeRelayHandshake key (MagicWormhole.Side side) =
  (toS @Text @ByteString "please relay ") <> token <> (toS @Text @ByteString " for side ") <> sideBytes <> "\n"
  where
    subkey = deriveKeyFromPurpose RelayHandshake key
    token = toS (toLower (toS @ByteString @Text (hex subkey)))
    sideBytes = toS @Text @ByteString side

makeRecordKeys :: SecretBox.Key -> Either CryptoError (SecretBox.Key, SecretBox.Key)
makeRecordKeys key =
  maybe (Left (KeyGenError "Could not generate record keys")) Right keyPair
  where
    keyPair = (,) <$> makeSenderRecordKey key
              <*> makeReceiverRecordKey key
    makeSenderRecordKey :: SecretBox.Key -> Maybe SecretBox.Key
    makeSenderRecordKey = Saltine.decode . (deriveKeyFromPurpose SenderRecord)
    makeReceiverRecordKey :: SecretBox.Key -> Maybe SecretBox.Key
    makeReceiverRecordKey = Saltine.decode . (deriveKeyFromPurpose ReceiverRecord)

-- |'transitExchange' exchanges transit message with the peer.
-- Sender sends a transit message with its abilities and hints.
-- Receiver sends either another Transit message or an Error message.
senderTransitExchange :: MagicWormhole.EncryptedConnection -> [ConnectionHint] -> IO (Either CommunicationError TransitMsg)
senderTransitExchange conn hs = do
  let abilities' = [Ability DirectTcpV1, Ability RelayV1]
  (_, rxMsg) <- concurrently (sendTransitMsg conn abilities' hs) receiveTransitMsg
  case eitherDecode (toS rxMsg) of
    Right t@(Transit _ _) -> return (Right t)
    Left s -> return (Left (TransitError (toS s)))
    Right (Error errstr) -> return (Left (TransitError errstr))
    Right (Answer _) -> return (Left (TransitError "Answer message from the peer is unexpected"))
  where
    receiveTransitMsg = do
      -- receive the transit from the receiving side
      responseMsg <- receiveWormholeMessage conn
      return responseMsg

sendTransitMsg :: MagicWormhole.EncryptedConnection -> [Ability] -> [ConnectionHint] -> IO ()
sendTransitMsg conn abilities' hints' = do
  -- create transit message
  let txTransitMsg = Transit abilities' (Set.fromList hints')
  let encodedTransitMsg = toS (encode txTransitMsg)
  -- send the transit message (dictionary with key as "transit" and value as abilities)
  MagicWormhole.sendMessage conn (MagicWormhole.PlainText encodedTransitMsg)

decodeTransitMsg :: ByteString -> Either CommunicationError TransitMsg
decodeTransitMsg received =
  case eitherDecode (toS received) of
    Right transitMsg -> Right transitMsg
    Left err -> Left $ TransitError (toS err)

sendOffer :: MagicWormhole.EncryptedConnection -> MagicWormhole.Offer -> IO ()
sendOffer conn offer =
  MagicWormhole.sendMessage conn (MagicWormhole.PlainText (toS (encode offer)))

-- | receive a message over wormhole and try to decode it as an offer message.
-- If it is not an offer message, pass the raw bytestring as a Left value.
receiveOffer :: MagicWormhole.EncryptedConnection -> IO (Either ByteString MagicWormhole.Offer)
receiveOffer conn = do
  received <- receiveWormholeMessage conn
  case eitherDecode (toS received) of
    Right msg@(MagicWormhole.Message _) -> return $ Right msg
    Right file@(MagicWormhole.File _ _) -> return $ Right file
    Right dir@(MagicWormhole.Directory _ _ _ _ _) -> return $ Right dir
    Left _ -> return $ Left received

receiveMessageAck :: MagicWormhole.EncryptedConnection -> IO (Either CommunicationError ())
receiveMessageAck conn = do
  rxTransitMsg <- receiveWormholeMessage conn
  case eitherDecode (toS rxTransitMsg) of
    Left s -> return $ Left (TransitError (show s))
    Right (Answer (MessageAck msg')) | msg' == "ok" -> return $ Right ()
                                     | otherwise -> return $ Left (TransitError "Message ack failed")
    Right s -> return $ Left (TransitError (show s))

sendMessageAck :: MagicWormhole.EncryptedConnection -> Text -> IO ()
sendMessageAck conn msg = do
  let ackMessage = Answer (MessageAck msg)
  MagicWormhole.sendMessage conn (MagicWormhole.PlainText (toS (encode ackMessage)))

senderOfferExchange :: MagicWormhole.EncryptedConnection -> FilePath -> IO (Either Text FilePath)
senderOfferExchange conn path = do
  (filePath, rx) <- concurrently sendFileOrDirOffer receiveResponse
  -- receive file ack message {"answer": {"file_ack": "ok"}}
  case eitherDecode (toS rx) of
    Left s -> return $ Left (toS s)
    Right (Error errstr) -> return $ Left (toS errstr)
    Right (Answer (FileAck msg)) | msg == "ok" -> return (Right filePath)
                                 | otherwise -> return $ Left "Did not get file ack. Exiting"
    Right (Answer (MessageAck _)) -> return $ Left "expected file ack, got message ack instead"
    Right (Transit _ _) -> return $ Left "unexpected transit message"
  where
    sendFileOrDirOffer :: IO FilePath
    sendFileOrDirOffer = do
      isDir <- isDirectory <$> getFileStatus path
      if isDir
        then sendDirOffer
        else sendFileOffer
    receiveResponse :: IO ByteString
    receiveResponse = do
      rxFileOffer <- receiveWormholeMessage conn
      return rxFileOffer
    getFileSize :: FilePath -> IO FileOffset
    getFileSize file = fileSize <$> getFileStatus file
    sendFileOffer = do
      size <- getFileSize path
      let fileOffer = MagicWormhole.File (toS (takeFileName path)) size
      sendOffer conn fileOffer
      return path
    sendDirOffer = do
      (zipFilePath, (totalFiles, totalSize)) <- zipDir path
      size <- getFileSize zipFilePath
      let dirOffer = MagicWormhole.Directory MagicWormhole.ZipFileDeflated (toS (takeBaseName (dropTrailingPathSeparator path))) (fromIntegral size) (fromIntegral totalSize) (fromIntegral totalFiles)
      sendOffer conn dirOffer
      return zipFilePath

receiveWormholeMessage :: MagicWormhole.EncryptedConnection -> IO ByteString
receiveWormholeMessage conn = do
  MagicWormhole.PlainText msg <- atomically $ MagicWormhole.receiveMessage conn
  return msg

sendWormholeMessage :: MagicWormhole.EncryptedConnection -> BL.ByteString -> IO ()
sendWormholeMessage conn msg =
  MagicWormhole.sendMessage conn (MagicWormhole.PlainText (toS msg))

data InvalidHandshake = InvalidHandshake
                      | InvalidRelayHandshake
  deriving (Show, Eq)

instance E.Exception InvalidHandshake where

relayHandshakeExchange :: TCPEndpoint -> SecretBox.Key -> MagicWormhole.Side -> IO ()
relayHandshakeExchange ep key side = do
  r <- sendRelayHandshake >> receiveAck
  if r == "ok\n"
    then return ()
    else throwIO InvalidRelayHandshake
  where
    sendRelayHandshake = sendBuffer ep sHandshakeMsg
    sHandshakeMsg = makeRelayHandshake key side
    receiveAck = recvByteString (BS.length rHandshakeMsg)
    rHandshakeMsg = "ok\n"
    recvByteString n = recvBuffer ep n

senderHandshakeExchange :: TCPEndpoint -> SecretBox.Key -> MagicWormhole.Side -> IO (Either InvalidHandshake ())
senderHandshakeExchange ep key side = do
  when (conntype ep == Just RelayV1) $ do
    relayHandshakeExchange ep key side
  (_, r) <- concurrently sendHandshake rxHandshake
  if r == rHandshakeMsg
    then do
    _ <- sendGo
    return $ Right ()
    else do
    _ <- sendNeverMind
    return $ Left InvalidHandshake
  where
    sendHandshake = sendBuffer ep sHandshakeMsg
    rxHandshake = recvByteString (BS.length rHandshakeMsg)
    sendGo = sendBuffer ep (toS @Text @ByteString "go\n")
    sendNeverMind = sendBuffer ep (toS @Text @ByteString "nevermind\n")
    sHandshakeMsg = makeSenderHandshake key
    rHandshakeMsg = makeReceiverHandshake key
    recvByteString n = recvBuffer ep n

receiverHandshakeExchange :: TCPEndpoint -> SecretBox.Key -> MagicWormhole.Side -> IO (Either InvalidHandshake ())
receiverHandshakeExchange ep key side = do
  when (conntype ep == Just RelayV1) $ do
    relayHandshakeExchange ep key side
  (_, r') <- concurrently sendHandshake rxHandshake
  r'' <- recvByteString (BS.length "go\n")
  if (r' <> r'') == sHandshakeMsg <> "go\n"
    then return $ Right ()
    else return $ Left InvalidHandshake
    where
        sendHandshake = sendBuffer ep rHandshakeMsg
        rxHandshake = recvByteString (BS.length sHandshakeMsg)
        sHandshakeMsg = makeSenderHandshake key
        rHandshakeMsg = makeReceiverHandshake key
        recvByteString n = recvBuffer ep n
    
makeAckMessage :: SecretBox.Key -> ByteString -> Either CryptoError CipherText
makeAckMessage key sha256Sum =
  let transitAckMsg = TransitAck "ok" (toS @ByteString @Text sha256Sum)
  in
    encrypt key Saltine.zero (PlainText (BL.toStrict (encode transitAckMsg)))

sendRecord :: TCPEndpoint -> ByteString -> IO (Either CommunicationError Int)
sendRecord ep record = do
  -- send size of the encrypted payload as 4 bytes, then send record
  -- format sz as a fixed 4 byte bytestring
  let payloadSize = word32BE (fromIntegral (BS.length record))
      payload = byteString record
      packet = payloadSize <> payload
  res <- try $ sendBuffer ep (BL.toStrict (toLazyByteString packet)) :: IO (Either IOError Int)
  case res of
    Left e -> return $ Left (ConnectionError (show e))
    Right x -> return $ Right x

receiveRecord :: TCPEndpoint -> SecretBox.Key -> IO (Either CryptoError ByteString)
receiveRecord ep key = do
  -- read 4 bytes that consists of length
  -- read as much bytes specified by the length. That would be encrypted record
  -- decrypt the record
    lenBytes <- recvBuffer ep 4
    let len = runGet getWord32be (BL.fromStrict lenBytes)
    encRecord <- recvBuffer ep (fromIntegral len)
    case decrypt key (CipherText encRecord) of
      Left e -> return $ Left e
      Right (PlainText plaintext, _) -> return $ Right plaintext

generateTransitSide :: MonadRandom m => m MagicWormhole.Side
generateTransitSide = do
  randomBytes <- getRandomBytes 8
  pure . MagicWormhole.Side . toS @ByteString . convertToBase Base16 $ (randomBytes :: ByteString)

type DirState = (Int, FileOffset)

-- | Given an input FilePath representing a directory, zip
-- the entire directory contents and return the path to the
-- zip file and a state (number of files and total size of all
-- the files).
zipDir :: FilePath -> IO (FilePath, DirState)
zipDir filePath = do
  systemTmpDir <- getTemporaryDirectory
  tmpDir <- createTempDirectory systemTmpDir "wormhole"
  let dirName = takeBaseName (dropTrailingPathSeparator filePath)
  let zipFileName = tmpDir </> dirName <.> "zip"
  ((_, stats), _) <- concurrently
                     (runStateT (dirStats filePath) (0,0))
                     (do
                         createArchive zipFileName $
                           packDirRecur Deflate mkEntrySelector filePath
                         withArchive zipFileName $ do
                           forEntries $ \selector -> do
                             mode <- liftIO $ getFileMode (dirName </> unEntrySelector selector)
                             setExternalFileAttrs (fromIntegral (mode `shiftL` 16)) selector)
  return (zipFileName, stats)
    where
      getFileMode :: FilePath -> IO FileMode
      getFileMode file = fileMode <$> getFileStatus file

dirStats :: FilePath -> StateT DirState IO ()
dirStats filePath = do
  pathWalk filePath $ \root _dirs files -> do
      forM_ files $ \file -> do
        size <- liftIO (getFileSize (root </> file))
        (numFiles, totalSize) <- get
        put (numFiles + 1, totalSize + size)
          where
            getFileSize :: FilePath -> IO FileOffset
            getFileSize file = fileSize <$> getFileStatus file

-- | unzip the given zip file into the especified directory
-- under current working directory
unzipInto :: FilePath -> FilePath -> IO ()
unzipInto dirname zipFilePath = withArchive zipFilePath (unpackInto dirname)
