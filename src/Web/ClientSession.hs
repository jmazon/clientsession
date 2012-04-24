{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}
---------------------------------------------------------
--
-- |
--
-- Module        : Web.ClientSession
-- Copyright     : Michael Snoyman
-- License       : BSD3
--
-- Maintainer    : Michael Snoyman <michael@snoyman.com>
-- Stability     : Stable
-- Portability   : portable
--
-- Stores session data in a client cookie.  In order to do so,
-- we:
--
-- * Encrypt the cookie data using AES in CTR mode.  This allows
-- you to store sensitive information on the client side without
-- worrying about eavesdropping.
--
-- * Authenticate the encrypted cookie data using
-- Skein-MAC-512-256.  Besides detecting potential errors in
-- storage or transmission of the cookies (integrity), the MAC
-- also avoids malicious modifications of the cookie data by
-- assuring you that the cookie data really was generated by this
-- server (authenticity).
--
-- * Encode everything using Base64.  Thus we avoid problems with
-- non-printable characters by giving the browser a simple
-- string.
--
-- Simple usage of the library involves just calling
-- 'getDefaultKey' on the startup of your server, 'encryptIO'
-- when serializing cookies and 'decrypt' when parsing then back.
--
---------------------------------------------------------
module Web.ClientSession
    ( -- * Automatic key generation
      Key(..)
    , IV
    , randomIV
    , mkIV
    , getKey
    , defaultKeyFile
    , getDefaultKey
    , initKey
      -- * Actual encryption/decryption
    , encrypt
    , encryptIO
    , decrypt
    ) where

-- from base
import Control.Monad (guard, when)
import qualified Data.IORef as I
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent (forkIO)

-- from directory
import System.Directory (doesFileExist)

-- from bytestring
import qualified Data.ByteString as S
import qualified Data.ByteString.Base64 as B

-- from cereal
import Data.Serialize (encode, decode)

-- from tagged
import Data.Tagged (Tagged, untag)

-- from crypto-api
import Crypto.Classes (buildKey, constTimeEq)
import Crypto.Random (genSeedLength, reseed)
import Crypto.Types (ByteLength)
import qualified Crypto.Modes as Modes

-- from cryptocipher
import qualified Crypto.Cipher.AES as A

-- from skein
import Crypto.Skein (skeinMAC', Skein_512_256)

-- from entropy
import System.Entropy (getEntropy)

-- from cprng-aes
import Crypto.Random.AESCtr (AESRNG, makeSystem, genRandomBytes)

-- | The keys used to store the cookies.  We have an AES key used
-- to encrypt the cookie and a Skein-MAC-512-256 key used verify
-- the authencity and integrity of the cookie.  The AES key needs
-- to have exactly 32 bytes (256 bits) while Skein-MAC-512-256
-- should have 64 bytes (512 bits).
--
-- See also 'getDefaultKey' and 'initKey'.
data Key = Key { aesKey :: A.AES256
                 -- ^ AES key with 32 bytes.
               , macKey :: S.ByteString -> Skein_512_256
                 -- ^ Skein-MAC key.  Instead of storing the key
                 -- data, we store a partially applied function
                 -- for calculating the MAC (see 'skeinMAC'').
               }

-- | Dummy 'Show' instance.
instance Show Key where
    show _ = "<Web.ClientSession.Key>"

-- | The initialization vector used by AES.  Should be exactly 16
-- bytes long.
type IV = Modes.IV A.AES256

-- | Construct an initialization vector from a 'S.ByteString'.
-- Fails if there isn't exactly 16 bytes.
mkIV :: S.ByteString -> Maybe IV
mkIV bs = case (S.length bs, decode bs) of
            (16, Right iv) -> Just iv
            _              -> Nothing

-- | Randomly construct a fresh initialization vector.  You
-- /should not/ reuse initialization vectors.
randomIV :: IO IV
randomIV = aesRNG

-- | The default key file.
defaultKeyFile :: FilePath
defaultKeyFile = "client_session_key.aes"

-- | Simply calls 'getKey' 'defaultKeyFile'.
getDefaultKey :: IO Key
getDefaultKey = getKey defaultKeyFile

-- | Get a key from the given text file.
--
-- If the file does not exist or is corrupted a random key will
-- be generated and stored in that file.
getKey :: FilePath     -- ^ File name where key is stored.
       -> IO Key       -- ^ The actual key.
getKey keyFile = do
    exists <- doesFileExist keyFile
    if exists
        then S.readFile keyFile >>= either (const newKey) return . initKey
        else newKey
  where
    newKey = do
        (bs, key') <- randomKey
        S.writeFile keyFile bs
        return key'

-- | Generate a random 'Key'.  Besides the 'Key', the
-- 'ByteString' passed to 'initKey' is returned so that it can be
-- saved for later use.
randomKey :: IO (S.ByteString, Key)
randomKey = do
    bs <- getEntropy 96
    case initKey bs of
        Left e -> error $ "Web.ClientSession.randomKey: never here, " ++ e
        Right key -> return (bs, key)

-- | Initializes a 'Key' from a random 'S.ByteString'.  Fails if
-- there isn't exactly 96 bytes (256 bits for AES and 512 bits
-- for Skein-MAC-512-512).
initKey :: S.ByteString -> Either String Key
initKey bs | S.length bs /= 96 = Left $ "Web.ClientSession.initKey: length of " ++
                                         show (S.length bs) ++ " /= 96."
initKey bs = case buildKey preAesKey of
               Nothing -> Left $ "Web.ClientSession.initKey: unknown error with buildKey."
               Just k  -> Right $ Key { aesKey = k
                                      , macKey = skeinMAC' preMacKey }
    where
      (preMacKey, preAesKey) = S.splitAt 64 bs

-- | Same as 'encrypt', however randomly generates the
-- initialization vector for you.
encryptIO :: Key -> S.ByteString -> IO S.ByteString
encryptIO key x = do
    iv <- randomIV
    return $ encrypt key iv x

-- | Encrypt (AES-CTR), authenticate (Skein-MAC-512-256) and
-- encode (Base64) the given cookie data.  The returned byte
-- string is ready to be used in a response header.
encrypt :: Key          -- ^ Key of the server.
        -> IV           -- ^ New, random initialization vector (see 'randomIV').
        -> S.ByteString -- ^ Serialized cookie data.
        -> S.ByteString -- ^ Encoded cookie data to be given to
                        -- the client browser.
encrypt key iv x = B.encode final
  where
    (encrypted, _) = Modes.ctr' Modes.incIV (aesKey key) iv x
    toBeAuthed     = encode iv `S.append` encrypted
    auth           = macKey key toBeAuthed
    final          = encode auth `S.append` toBeAuthed

-- | Decode (Base64), verify the integrity and authenticity
-- (Skein-MAC-512-256) and decrypt (AES-CTR) the given encoded
-- cookie data.  Returns the original serialized cookie data.
-- Fails if the data is corrupted.
decrypt :: Key                -- ^ Key of the server.
        -> S.ByteString       -- ^ Encoded cookie data given by the browser.
        -> Maybe S.ByteString -- ^ Serialized cookie data.
decrypt key dataBS64 = do
    dataBS <- either (const Nothing) Just $ B.decode dataBS64
    guard (S.length dataBS >= 48) -- 16 bytes of IV + 32 bytes of Skein-MAC-512-256
    let (auth, toBeAuthed) = S.splitAt 32 dataBS
        auth' = macKey key toBeAuthed
    guard (encode auth' `constTimeEq` auth)
    let (iv_e, encrypted) = S.splitAt 16 toBeAuthed
    iv <- either (const Nothing) Just $ decode iv_e
    let (x, _) = Modes.unCtr' Modes.incIV (aesKey key) iv encrypted
    return x

-- Significantly more efficient random IV generation. Initial
-- benchmarks placed it at 6.06 us versus 1.69 ms for Modes.getIVIO,
-- since it does not require /dev/urandom I/O for every call.

data AESState =
    ASt {-# UNPACK #-} !AESRNG -- Our CPRNG using AES on CTR mode
        {-# UNPACK #-} !Int    -- How many IVs were generated with this
                               -- AESRNG.  Used to control reseeding.

-- | Construct initial state of the CPRNG.
aesSeed :: IO AESState
aesSeed = do
  rng <- makeSystem
  return $! ASt rng 0

-- | Reseed the CPRNG with new entropy from the system pool.
aesReseed :: IO ()
aesReseed = do
  let len :: Tagged AESRNG ByteLength
      len = genSeedLength
  ent <- getEntropy (untag len)
  I.atomicModifyIORef aesRef $
       \(ASt rng _) ->
           case reseed ent rng of
             Right rng' -> (ASt rng' 0, ())
             Left  _    -> (ASt rng  0, ())
             -- Use the old RNG, but force a reseed
             -- after another 'threshold' uses of it.
             -- In theory, we will never reach this
             -- branch, but if we do, we're safe.

-- | 'IORef' that keeps the current state of the CPRNG.  Yep,
-- global state.  Used in thread-safe was only, though.
aesRef :: I.IORef AESState
aesRef = unsafePerformIO $ aesSeed >>= I.newIORef
{-# NOINLINE aesRef #-}

-- | Construct a new 16-byte IV using our CPRNG.  Forks another
-- thread to reseed the CPRNG should its usage count reach a
-- hardcoded threshold.
aesRNG :: IO IV
aesRNG = do
  (bs, count) <-
      I.atomicModifyIORef aesRef $ \(ASt rng count) ->
          let (bs', rng') = genRandomBytes rng 16
          in (ASt rng' (succ count), (bs', count))
  when (count == threshold) $ void $ forkIO aesReseed
  either (error . show) return $ decode bs
 where
  void f = f >> return ()

-- | How many IVs should be generated before reseeding the CPRNG.
-- This number depends basically on how paranoid you are.  We
-- think 100.000 is a good compromise: larger numbers give only a
-- small performance advantage, while it still is a small number
-- since we only generate 1.5 MiB of random data between reseeds.
threshold :: Int
threshold = 100000
