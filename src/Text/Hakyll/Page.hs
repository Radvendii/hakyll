module Text.Hakyll.Page 
    ( Page,
      fromContext,
      addContext,
      getBody,
      readPage,
      pageFromList
    ) where

import qualified Data.Map as M
import qualified Data.List as L
import qualified Data.ByteString.Lazy.Char8 as B
import Data.Maybe
import Control.Monad

import System.FilePath
import System.IO

import Text.Hakyll.Util
import Text.Hakyll.Renderable
import Text.Pandoc

-- | A Page is basically key-value mapping. Certain keys have special
--   meanings, like for example url, body and title.
data Page = Page (M.Map B.ByteString B.ByteString)

fromContext :: (M.Map B.ByteString B.ByteString) -> Page
fromContext = Page

-- | Add a key-value mapping to the Page.
addContext :: String -> String -> Page -> Page
addContext key value (Page page) = Page $ M.insert (B.pack key) (B.pack value) page

packPair :: (String, String) -> (B.ByteString, B.ByteString)
packPair (a, b) = (B.pack a, B.pack b)

-- | Get the URL for a certain page. This should always be defined. If
--   not, it will return trash.html.
getPageURL :: Page -> String
getPageURL (Page page) =
    let result = M.lookup (B.pack "url") page
    in case result of (Just url) -> B.unpack url
                      Nothing    -> error "URL is not defined."

-- | Get the body for a certain page. When not defined, the body will be
--   empty.
getBody :: Page -> B.ByteString
getBody (Page page) = fromMaybe B.empty $ M.lookup (B.pack "body") page

writerOptions :: WriterOptions
writerOptions = defaultWriterOptions

renderFunction :: String -> (String -> String)
renderFunction ".html" = id
renderFunction ext = writeHtmlString writerOptions .
                     readFunction ext defaultParserState
    where readFunction ".markdown" = readMarkdown
          readFunction ".md"       = readMarkdown
          readFunction ".tex"      = readLaTeX
          readFunction _           = readMarkdown

readMetaData :: Handle -> IO [(String, String)]
readMetaData handle = do
    line <- hGetLine handle
    if isDelimiter line then return []
                        else do others <- readMetaData handle
                                return $ (trimPair . break (== ':')) line : others
        where trimPair (key, value) = (trim key, trim $ tail value)

isDelimiter :: String -> Bool
isDelimiter = L.isPrefixOf "---"

-- | Used for caching of files.
cachePage :: Page -> IO ()
cachePage page@(Page mapping) = do
    let destination = toCache $ getURL page
    makeDirectories destination
    handle <- openFile destination WriteMode
    hPutStrLn handle "---"
    mapM_ (writePair handle) $ M.toList $ M.delete (B.pack "body") mapping
    hPutStrLn handle "---"
    B.hPut handle $ getBody page
    hClose handle
    where writePair h (k, v) = B.hPut h k >>
                               B.hPut h (B.pack ": ") >>
                               B.hPut h v >>
                               hPutStrLn h ""

-- | Read a page from a file. Metadata is supported, and if the filename
--   has a .markdown extension, it will be rendered using pandoc. Note that
--   pages are not templates, so they should not contain $identifiers.
readPage :: FilePath -> IO Page
readPage pagePath = do
    -- Check cache.
    getFromCache <- isCacheValid cacheFile [pagePath]
    let path = if getFromCache then cacheFile else pagePath

    -- Read file.
    handle <- openFile path ReadMode
    line <- hGetLine handle
    (context, body) <- if isDelimiter line
                            then do md <- readMetaData handle
                                    c <- hGetContents handle
                                    return (md, c)
                            else hGetContents handle >>= \b -> return ([], line ++ b)

    -- Render file
    let rendered = B.pack $ (renderFunction $ takeExtension path) body
    seq rendered $ hClose handle
    let page = addContext "url" url $ Page $ M.fromList $ (B.pack "body", rendered) : map packPair context

    -- Cache if needed
    if getFromCache then return () else cachePage page
    return page
    where url = toURL pagePath
          cacheFile = toCache url

-- | Create a key-value mapping page from an association list.
pageFromList :: [(String, String)] -> Page
pageFromList = Page . M.fromList . map packPair

-- Make pages renderable
instance Renderable Page where
    getDependencies = (:[]) . flip addExtension ".html" . dropExtension . getPageURL
    getURL = getPageURL
    toContext (Page mapping) = return mapping
