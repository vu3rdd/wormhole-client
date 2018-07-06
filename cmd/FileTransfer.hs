{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module FileTransfer
  ( sendFile
  )
where

import Protolude

import qualified Crypto.Spake2 as Spake2

import System.Posix.Files
  ( getFileStatus
  , fileSize
  )
import System.Posix.Types
  ( FileOffset
  )
import Data.Aeson
  ( encode
  , eitherDecode
  )

import qualified MagicWormhole
import FileTransfer.Internal.Network
import FileTransfer.Internal.Protocol
import FileTransfer.Internal.Messages

import Helper

type Password = ByteString


getFileSize :: FilePath -> IO FileOffset
getFileSize file = fileSize <$> getFileStatus file

transitPurpose :: MagicWormhole.AppID -> ByteString
transitPurpose (MagicWormhole.AppID appID) = toS appID <> "/transit-key"

transitExchange :: MagicWormhole.EncryptedConnection -> IO (Either Text TransitMsg)
transitExchange conn = do
  (_, rxMsg) <- concurrently sendTransitMsg receiveTransitMsg
  case eitherDecode (toS rxMsg) of
    Right t@(Transit as hs) -> return (Right t)
    Left s -> return (Left (toS s))
    Right (Error errstr) -> return (Left errstr)
  where
    sendTransitMsg = do
      -- create abilities
      let abilities' = [Ability DirectTcpV1]
      port' <- allocateTcpPort
      let hint = Hint DirectTcpV1 0.0 "127.0.0.1" (fromIntegral (toInteger port'))
      let hints' = [Direct hint]

      -- create transit message
      let txTransitMsg = Transit abilities' hints'
      let encodedTransitMsg = toS (encode txTransitMsg)

      -- send the transit message (dictionary with key as "transit" and value as abilities)
      MagicWormhole.sendMessage conn (MagicWormhole.PlainText encodedTransitMsg)
    receiveTransitMsg = do
      -- receive the transit from the receiving side
      MagicWormhole.PlainText responseMsg <- atomically $ MagicWormhole.receiveMessage conn
      return responseMsg

offerExchange :: MagicWormhole.EncryptedConnection -> FilePath -> IO (Either Text ())
offerExchange conn path = do
  (_,rx) <- concurrently sendOffer receiveResponse
  -- receive file ack message {"answer": {"file_ack": "ok"}}
  case eitherDecode (toS rx) of
    Left s -> return $ Left (toS s)
    Right (Error errstr) -> return $ Left (toS errstr)
    Right (Answer (FileAck msg)) | msg == "ok" -> return (Right ())
                                 | otherwise -> return $ Left "Did not get file ack. Exiting"
    Right (Answer (MsgAck _)) -> return $ Left "expected file ack, got message ack instead"
    Right (Transit _ _) -> return $ Left "unexpected transit message"
  where
    sendOffer :: IO ()
    sendOffer = do
      size <- getFileSize path
      let fileOffer = MagicWormhole.File (toS path) size
      MagicWormhole.sendMessage conn (MagicWormhole.PlainText (toS (encode fileOffer)))
    receiveResponse :: IO ByteString
    receiveResponse = do
      MagicWormhole.PlainText rxFileOffer <- atomically $ MagicWormhole.receiveMessage conn
      return rxFileOffer

sendFile :: MagicWormhole.Session -> MagicWormhole.AppID -> Password -> FilePath -> IO () -- Response
sendFile session appid password filepath = do
--   -- steps
--   -- * first establish a wormhole session with the receiver and
--   --   then talk the filetransfer protocol over it as follows.
  nameplate <- MagicWormhole.allocate session
  mailbox <- MagicWormhole.claim session nameplate
  peer <- MagicWormhole.open session mailbox  -- XXX: We should run `close` in the case of exceptions?
  let (MagicWormhole.Nameplate n) = nameplate
  printSendHelpText $ toS n <> "-" <> toS password
  MagicWormhole.withEncryptedConnection peer (Spake2.makePassword (toS n <> "-" <> password))
    (\conn -> do
        -- exchange abilities
        transitResp <- transitExchange conn
        case transitResp of
          Left s -> panic s
          Right (Transit abilities' hints') -> do
            -- send offer for the file
            offerResp <- offerExchange conn filepath
            case offerResp of
              Left s -> panic s
              Right _ -> do
                -- derive key
                let sessionKey = MagicWormhole.sharedKey conn
                let transitKey = MagicWormhole.deriveKey sessionKey (transitPurpose appid)
                runTransitProtocol transitKey abilities' hints'
          Right _ -> panic "error sending transit message"
    )

