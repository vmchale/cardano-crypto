-- |
-- Module      : Cardano.Crypto.Wallet
-- Description : HD Wallet routines
-- Maintainer  : vincent@typed.io
--
-- This provide similar functionality than BIP32 but using
-- Ed25519 arithmetic instead of P256K1 arithmethic.
--
-- Key can be hierarchically derived from private key in two
-- fashion: Hardened or Normal.
--
-- In the hardened scheme, the child secret key is not linearly
-- derived, so that the child public key have no way
-- to be efficiently computed from the parent public key.
--
-- The normal scheme, allows anyone to derive public keys from
-- public key.
--
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE PatternSynonyms     #-}

module Cardano.Crypto.Wallet
    ( ChainCode(..)
    , DerivationScheme(..)
    , pattern LatestScheme
    -- * Extended Private & Public types
    , XPrv
    , XPub(..)
    , XSignature
    , generate
    , xprv
    , xpub
    , xsignature
    , unXPrv
    , unXPub
    , unXSignature
    , toXPub
    , xPubGetPublicKey
    , xPrvChangePass
    -- * Derivation function
    , deriveXPrv
    , deriveXPub
    -- * Signature & Verification from extended types
    , sign
    , verify
    ) where

import qualified Foundation as F

import           Control.DeepSeq                 (NFData)
import           Control.Arrow                   (second)
import           Crypto.Error                    (throwCryptoError, CryptoFailable(..), CryptoError(..))
import qualified Crypto.MAC.HMAC                 as HMAC
import qualified Crypto.PubKey.Ed25519           as Ed25519
import           Data.ByteArray                  (ByteArrayAccess, convert)
import qualified Data.ByteArray                  as B (append, length, splitAt)
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString.Char8           as BC
import           Data.Hashable                   (Hashable)
import           Data.Word
import           GHC.Generics                    (Generic)

import           Cardano.Crypto.Wallet.Encrypted
import           Cardano.Crypto.Wallet.Pure      ({-XPub (..),-} hFinalize,
                                                  hInitSeed)
import           Cardano.Crypto.Wallet.Types

import           Inspector.Display
import           Inspector.Parser

import           GHC.Stack

newtype XPrv = XPrv EncryptedKey
    deriving (NFData, ByteArrayAccess)
instance Display XPrv where
    display = displayByteArrayAccess
instance HasParser XPrv where
    getParser = strParser >>= parseByteArray >>= \s -> case xprv (s :: ByteString) of
        Left err -> reportError $ Expected "xPrv" (F.fromList err)
        Right e  -> pure e

data XPub = XPub
    { xpubPublicKey :: !ByteString
    , xpubChaincode :: !ChainCode
    } deriving (Generic)

instance NFData XPub
instance Display XPub where
    display = displayByteArrayAccess . unXPub
instance HasParser XPub where
    getParser = strParser >>= parseByteArray >>= \s -> case xpub (s :: ByteString) of
        Left err -> reportError $ Expected "xPub" (F.fromList err)
        Right e  -> pure e

newtype XSignature = XSignature
    { unXSignature :: ByteString
    } deriving (Show, Eq, Ord, NFData, Hashable)
instance Display XSignature where
    display (XSignature bs) = displayByteArrayAccess bs
instance HasParser XSignature where
    getParser = strParser >>= parseByteArray >>= \s -> case xsignature s of
        Left err -> reportError $ Expected "XSignature" (F.fromList err)
        Right e  -> pure e

-- | Generate a new XPrv
--
-- The seed need to be at least 32 bytes, otherwise an asynchronous error in throwned
generate :: (ByteArrayAccess passPhrase, ByteArrayAccess seed)
         => seed
         -> passPhrase
         -> XPrv
generate seed passPhrase
    | B.length seed < 32 = error ("Wallet.generate: seed need to be >= 32 bytes, got : " ++ show (B.length seed))
    | otherwise          = loop 1
  where
    phrase :: Int -> ByteString
    phrase i = "Root Seed Chain " `B.append` BC.pack (show i)

    -- repeatdly try to generate from a seed, if we reach 1000th iteration we just bail
    -- this should find a candidate after 2 try on average
    loop i
        | i > 1000  = error "internal error: Wallet.generate looping forever"
        | otherwise =
            case encryptedCreate iL passPhrase iR of
                    CryptoPassed k -> XPrv k
                    CryptoFailed err
                        | err == CryptoError_SecretKeyStructureInvalid -> loop (i+1)
                        | otherwise                                    -> error "internal error: Wallet.generate: got error from encryptedCreate"
      where (iL, iR) = hFinalize
                     $ flip HMAC.update (phrase i)
                     $ hInitSeed seed

-- | Simple constructor
xprv :: ByteArrayAccess bin => bin -> Either String XPrv
xprv bs =
      maybe (Left "error: xprv need to be 128 bytes") (Right . XPrv)
    $ encryptedKey
    $ convert bs

unXPrv :: XPrv -> ByteString
unXPrv (XPrv e) = unEncryptedKey e

xpub :: ByteString -> Either String XPub
xpub bs
    | B.length bs /= 64 = Left ("error: xprv need to be 64 bytes: got " ++ show (B.length bs) ++ " bytes")
    | otherwise         =
        let (b1, b2) = B.splitAt 32 bs
         in Right $ XPub b1 (ChainCode $ convert b2)

unXPub :: XPub -> ByteString
unXPub (XPub pub (ChainCode cc)) = B.append pub cc

xsignature :: ByteString -> Either String XSignature
xsignature bs
    | B.length bs /= 64 = Left ("error: xsignature need to be 64 bytes: got " ++ show (B.length bs) ++ " bytes")
    | otherwise         = Right $ XSignature bs

-- | Generate extended public key from private key
toXPub :: HasCallStack => XPrv -> XPub
toXPub (XPrv ekey) = XPub pub (ChainCode cc)
  where (_,r)     = B.splitAt 64 $ convert ekey
        (pub, cc) = B.splitAt 32 r

-- | Return the Ed25519 public key associated with a XPub context
xPubGetPublicKey :: XPub -> Ed25519.PublicKey
xPubGetPublicKey (XPub pub _) =
    throwCryptoError $ Ed25519.publicKey pub

xPrvChangePass :: (ByteArrayAccess oldPassPhrase, ByteArrayAccess newPassPhrase)
               => oldPassPhrase -- ^ passphrase to decrypt the current encrypted key
               -> newPassPhrase -- ^ new passphrase to use for the new encrypted key
               -> XPrv
               -> XPrv
xPrvChangePass oldPass newPass (XPrv ekey) =
    XPrv $ encryptedChangePass oldPass newPass ekey

-- | Derive a child extended private key from an extended private key
deriveXPrv :: ByteArrayAccess passPhrase => DerivationScheme -> passPhrase -> XPrv -> Word32 -> XPrv
deriveXPrv ds passPhrase (XPrv ekey) n =
    XPrv (encryptedDerivePrivate ds ekey passPhrase n)

-- | Derive a child extended private key from an extended private key
deriveXPub :: DerivationScheme -> XPub -> Word32 -> Maybe XPub
deriveXPub ds (XPub pub (ChainCode cc)) n
    | n >= 0x8000000 = Nothing
    | otherwise      = Just $ uncurry XPub $ second ChainCode $ encryptedDerivePublic ds (pub,cc) n

sign :: (ByteArrayAccess passPhrase, ByteArrayAccess msg)
     => passPhrase
     -> XPrv
     -> msg
     -> XSignature
sign passphrase (XPrv ekey) ba =
    XSignature $ let (Signature sig) = encryptedSign ekey passphrase ba in sig

verify :: ByteArrayAccess msg => XPub -> msg -> XSignature -> Bool
verify (XPub point _) ba (XSignature signature) =
    let pub = throwCryptoError $ Ed25519.publicKey $ point
        sig = throwCryptoError $ Ed25519.signature $ signature
     in Ed25519.verify pub ba sig
