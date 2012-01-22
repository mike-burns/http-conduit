{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
-- | This module contains everything you need to initiate HTTP connections.  If
-- you want a simple interface based on URLs, you can use 'simpleHttp'. If you
-- want raw power, 'http' is the underlying workhorse of this package. Some
-- examples:
--
-- > -- Just download an HTML document and print it.
-- > import Network.HTTP.Conduit
-- > import qualified Data.ByteString.Lazy as L
-- >
-- > main = simpleHttp "http://www.haskell.org/" >>= L.putStr
--
-- This example uses interleaved IO to write the response body to a file in
-- constant memory space.
--
-- > import Data.Conduit.Binary (sinkFile)
-- > import Network.HTTP.Conduit
-- > import qualified Data.Conduit as C
-- >
-- > main :: IO ()
-- > main = do
-- >      request <- parseUrl "http://google.com/"
-- >      withManager $ \manager -> do
-- >          Response _ _ bsrc <- http request manager
-- >          bsrc C.$$ sinkFile "google.html"
--
-- The following headers are automatically set by this module, and should not
-- be added to 'requestHeaders':
--
-- * Content-Length
--
-- * Host
--
-- * Accept-Encoding (not currently set, but client usage of this variable /will/ cause breakage).
--
-- Any network code on Windows requires some initialization, and the network
-- library provides withSocketsDo to perform it. Therefore, proper usage of
-- this library will always involve calling that function at some point.  The
-- best approach is to simply call them at the beginning of your main function,
-- such as:
--
-- > import Network.HTTP.Conduit
-- > import qualified Data.ByteString.Lazy as L
-- > import Network (withSocketsDo)
-- >
-- > main = withSocketsDo
-- >      $ simpleHttp "http://www.haskell.org/" >>= L.putStr
module Network.HTTP.Conduit
    ( -- * Perform a request
      simpleHttp
    , httpLbs
    , http
    , httpLbsWithSink
    , httpWithSink
      -- * Datatypes
    , Proxy (..)
    , RequestBody (..)
    , Response (..)
      -- ** Request
    , Request
    , def
    , method
    , secure
    , host
    , port
    , path
    , queryString
    , requestHeaders
    , requestBody
    , proxy
    , rawBody
    , decompress
    , redirectCount
    , checkStatus
      -- * Manager
    , Manager
    , newManager
    , closeManager
    , withManager
      -- ** Settings
    , ManagerSettings
    , managerConnCount
    , managerCheckCerts
      -- *** Defaults
    , defaultCheckCerts
      -- * Utility functions
    , parseUrl
    , applyBasicAuth
    , addProxy
    , lbsResponse
      -- * Decompression predicates
    , alwaysDecompress
    , browserDecompress
      -- * Request bodies
    , urlEncodedBody
      -- * Exceptions
    , HttpException (..)
#if DEBUG
      -- * Debug
    , printOpenSockets
#endif
    ) where

import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as S8

import qualified Network.HTTP.Types as W
import Data.Default (def)

import Control.Exception.Lifted (throwIO)
import Control.Monad.Base (liftBase)
import Control.Monad.IO.Class (MonadIO (liftIO))

import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Data.Conduit.Blaze (builderToByteString)
import Control.Monad.Trans.Resource (ResourceT, ResourceIO)
import Control.Exception.Lifted (try, SomeException)

import Network.HTTP.Conduit.Request
import Network.HTTP.Conduit.Response
import Network.HTTP.Conduit.Manager
import Network.HTTP.Conduit.ConnInfo

-- | The most low-level function for initiating an HTTP request.
--
-- The first argument to this function gives a full specification
-- on the request: the host to connect to, whether to use SSL,
-- headers, etc. Please see 'Request' for full details.  The
-- second argument specifies which 'Manager' should be used.
--
-- This function then returns a 'Response' with a
-- 'C.Source'.  The 'Response' contains the status code
-- and headers that were sent back to us, and the
-- 'C.Source' contains the body of the request.  Note
-- that this 'C.Source' allows you to have fully
-- interleaved IO actions during your HTTP download, making it
-- possible to download very large responses in constant memory.
-- You may also directly connect the returned 'C.Source'
-- into a 'C.Sink', perhaps a file or another socket.
--
-- Note: Unlike previous versions, this function will perform redirects, as
-- specified by the 'redirectCount' setting.
http
    :: ResourceIO m
    => Request m
    -> Manager
    -> ResourceT m (Response (C.Source m S.ByteString))
http req0 manager = httpWithSink CL.sinkNull req0 manager

-- | Like the 'http' function, but takes an extra sink parameter. This sink
-- parameter is passed the 'ByteString' that is sent to the HTTP connection.
-- This can be useful for debugging.
httpWithSink
    :: ResourceIO m
    => C.Sink S.ByteString m ()
    -> Request m
    -> Manager
    -> ResourceT m (Response (C.Source m S.ByteString))
httpWithSink sink req0 manager = do
    res@(Response status hs body) <-
        if redirectCount req0 == 0
            then httpRaw sink req0 manager
            else go (redirectCount req0) req0
    case checkStatus req0 status hs of
        Nothing -> return res
        Just exc -> do
            body' <- C.prepareSource body
            C.sourceClose body'
            liftBase $ throwIO exc
  where
    go 0 _ = liftBase $ throwIO TooManyRedirects
    go count req = do
        res@(Response (W.Status code _) hs _) <- httpRaw sink req manager
        case (300 <= code && code < 400, lookup "location" hs) of
            (True, Just l'') -> do
                -- Prepend scheme, host and port if missing
                let l' =
                        case S8.uncons l'' of
                            Just ('/', _) -> concat
                                [ "http"
                                , if secure req then "s" else ""
                                , "://"
                                , S8.unpack $ host req
                                , ":"
                                , show $ port req
                                , S8.unpack l''
                                ]
                            _ -> S8.unpack l''
                l <- liftBase $ parseUrl l'
                let req' = req
                        { host = host l
                        , port = port l
                        , secure = secure l
                        , path = path l
                        , queryString = queryString l
                        , method =
                            -- According to the spec, this should *only* be for
                            -- status code 303. However, almost all clients
                            -- mistakenly implement it for 302 as well. So we
                            -- have to be wrong like everyone else...
                            if code == 302 || code == 303
                                then "GET"
                                else method l
                        }
                go (count - 1) req'
            _ -> return res

-- | Get a 'Response' without any redirect following.
httpRaw
     :: ResourceIO m
     => C.Sink S.ByteString m ()
     -> Request m
     -> Manager
     -> ResourceT m (Response (C.Source m S.ByteString))
httpRaw sink req m = do
    let builtRequest = requestBuilder req
    (connRelease, ci, isManaged) <- getConn req m
    bsrc <- C.bufferSource $ connSource ci
    builtRequest C.$$ builderToByteString C.=$ sink
    ex <- try $ builtRequest C.$$ builderToByteString C.=$ connSink ci
    case (ex :: Either SomeException (), isManaged) of
        -- Connection was reused, and might be been closed. Try again
        (Left _, Reused) -> do
            connRelease DontReuse
            http req m
        -- Not reused, so this is a real exception
        (Left e, Fresh) -> liftBase $ throwIO e
        -- Everything went ok, so the connection is good. If any exceptions get
        -- thrown in the rest of the code, just throw them as normal.
        (Right (), _) -> getResponse connRelease req bsrc

-- | Download the specified 'Request', returning the results as a 'Response'.
--
-- This is a simplified version of 'http' for the common case where you simply
-- want the response data as a simple datatype. If you want more power, such as
-- interleaved actions on the response body during download, you'll need to use
-- 'http' directly. This function is defined as:
--
-- @httpLbs = 'lbsResponse' . 'http'@
--
-- Even though the 'Response' contains a lazy bytestring, this
-- function does /not/ utilize lazy I/O, and therefore the entire
-- response body will live in memory. If you want constant memory
-- usage, you'll need to use @conduit@ packages's
-- 'C.Source' returned by 'http'.
--
-- Note: Unlike previous versions, this function will perform redirects, as
-- specified by the 'redirectCount' setting.
httpLbs :: ResourceIO m => Request m -> Manager -> ResourceT m (Response L.ByteString)
httpLbs r = httpLbsWithSink CL.sinkNull r

-- | Like the 'httpLbs' function, but takes an extra sink parameter. This sink
-- parameter is passed the 'ByteString' that is sent to the HTTP connection.
-- This can be useful for debugging.
httpLbsWithSink :: ResourceIO m
                => C.Sink S.ByteString m ()
                -> Request m
                -> Manager
                -> ResourceT m (Response L.ByteString)
httpLbsWithSink sink r = lbsResponse . httpWithSink sink r

-- | Download the specified URL, following any redirects, and
-- return the response body.
--
-- This function will 'throwIO' an 'HttpException' for any
-- response with a non-2xx status code (besides 3xx redirects up
-- to a limit of 10 redirects). It uses 'parseUrl' to parse the
-- input. This function essentially wraps 'httpLbsRedirect'.
--
-- Note: Even though this function returns a lazy bytestring, it
-- does /not/ utilize lazy I/O, and therefore the entire response
-- body will live in memory. If you want constant memory usage,
-- you'll need to use the @conduit@ package and 'http' or
-- 'httpRedirect' directly.
simpleHttp :: MonadIO m => String -> m L.ByteString
simpleHttp url = liftIO $ withManager $ \man -> do
    url' <- liftBase $ parseUrl url
    fmap responseBody $ httpLbs url' man
