{-# OPTIONS_GHC -XScopedTypeVariables #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Package
-- Copyright   :  (c) Juergen Nicklisch-Franken (aka Jutaro)
-- License     :  GNU-GPL
--
-- Maintainer  :  Juergen Nicklisch-Franken <info at leksah.org>
-- Stability   :  experimental
-- Portability :  portable
--
--
-- | The packages methods of ide.
--
---------------------------------------------------------------------------------


module IDE.Package (
    packageOpen
,   packageNew
,   packageConfig
,   packageBuild
,   packageDoc
,   packageClean
,   packageCopy
,   packageRun
,   nextError
,   previousError
,   activatePackage
,   deactivatePackage
,   getActivePackage

,   packageInstall
,   packageRegister
,   packageUnregister
,   packageTest
,   packageSdist
,   packageOpenDoc

,   getPackageDescriptionAndPath
,   getModuleTemplate
,   addModuleToPackageDescr
) where

import Graphics.UI.Gtk
import Control.Monad.Reader
import Distribution.Package hiding (depends,packageId)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.PackageDescription.Configuration
import Distribution.Verbosity
import System.FilePath
import Control.Concurrent
import System.Directory
import System.IO
import Prelude hiding (catch)
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as P
import Text.ParserCombinators.Parsec hiding(Parser)
import Data.Maybe(isJust,fromJust)
import Control.Exception hiding (try)

import IDE.Pane.Log
import Control.Event
import IDE.Core.State
import IDE.Pane.PackageEditor
import IDE.Pane.SourceBuffer
import IDE.Pane.PackageFlags
import IDE.Metainfo.Provider
import Distribution.Text (display)
import IDE.FileUtils (getConfigFilePathForLoad)
import MyMissing (replace)
import Distribution.ModuleName (ModuleName(..))
import Data.List (foldl')

packageNew :: IDEAction
packageNew = packageNew' (\fp -> activatePackage fp >> return ())

packageOpen :: IDEAction
packageOpen = do
    active <- readIDE activePack
    case active of
        Just p -> deactivatePackage
        Nothing -> return ()
    selectActivePackage
    return ()


getActivePackage :: IDEM (Maybe IDEPackage)
getActivePackage = do
    active <- readIDE activePack
    case active of
        Just p -> return (Just p)
        Nothing -> selectActivePackage

selectActivePackage :: IDEM (Maybe IDEPackage)
selectActivePackage = do
    ideR       <- ask
    window     <- readIDE window
    mbFilePath <- liftIO $choosePackageFile window
    case mbFilePath of
        Nothing -> return Nothing
        Just filePath -> do
            let ppath = dropFileName filePath
            exists <- liftIO $ doesFileExist (ppath </> "IDE.session")
            wantToLoadSession <-
                if exists
                    then liftIO $ do
                        md  <- messageDialogNew Nothing [] MessageQuestion ButtonsYesNo
                                $ "Load the session settings stored with this project?"
                        rid <- dialogRun md
                        widgetDestroy md
                        case rid of
                            ResponseYes ->  return True
                            otherwise   ->  return False
                    else return False
            if wantToLoadSession
                then triggerEvent ideR (LoadSession (ppath </> "IDE.session")) >> getActivePackage
                else activatePackage filePath

activatePackage :: FilePath -> IDEM (Maybe IDEPackage)
activatePackage filePath = do
    ideR <- ask
    let ppath = dropFileName filePath
    liftIO $ setCurrentDirectory ppath
    mbPackageD <- reifyIDE (\ideR session -> catch (do
        pd <- readPackageDescription normal filePath
        return (Just (flattenPackageDescription pd)))
            (\(e :: SomeException) -> do
                reflectIDE (ideMessage Normal ("Can't activate package " ++(show e))) ideR session
                return Nothing))
    case mbPackageD of
        Nothing -> return (Nothing)
        Just packageD -> do
            let packp = IDEPackage (package packageD) filePath (buildDepends packageD) [] [] [] [] [] [] [] []
            pack <- (do
                flagFileExists <- liftIO $ doesFileExist (ppath </> "IDE.flags")
                if flagFileExists
                    then liftIO $ readFlags (ppath </> "IDE.flags") packp
                    else return packp)
            modifyIDE_ (\ide -> return (ide{activePack = (Just pack)}))
            ide <- getIDE
            triggerEvent ideR ActivePack
            triggerEvent ideR (Sensitivity [(SensitivityProjectActive,True)])
            sb <- getSBActivePackage
            liftIO $ statusbarPop sb 1
            liftIO $ statusbarPush sb 1 (display $ packageId pack)
            return (Just pack)

deactivatePackage :: IDEAction
deactivatePackage = do
    ideR          <- ask
    oldActivePack <- readIDE activePack
    when (isJust oldActivePack) $ do
        triggerEvent ideR (SaveSession
            ((dropFileName . cabalFile . fromJust) oldActivePack </> "IDE.session"))
        return ()
    modifyIDE_ (\ide -> return (ide{activePack = Nothing}))
    ideR          <- ask
    triggerEvent ideR ActivePack
    when (isJust oldActivePack) $ do
        triggerEvent ideR (Sensitivity [(SensitivityProjectActive,False)])
        return ()
    sb            <- getSBActivePackage
    liftIO $ statusbarPop sb 1
    liftIO $ statusbarPush sb 1 ""
    return ()

packageConfig :: IDEAction
packageConfig = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> do
                mbPackageD  <- reifyIDE (\ideR session ->  catch (do
                    (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","configure"]
                                                    ++ (configFlags package))
                    oid <- forkIO(readOut log out)
                    eid <- forkIO (readErr log err)
                    pd  <- readPackageDescription normal (cabalFile package)
                    return (Just (flattenPackageDescription pd)))
                    (\(e :: SomeException) -> do
                            reflectIDE (ideMessage Normal (show e)) ideR session
                            return Nothing))
                case mbPackageD of
                    Just packageD -> do
                        modifyIDE_ (\ide -> return (ide{activePack =
                            Just package{depends=buildDepends packageD}}))
                        ask >>= \ideR -> triggerEvent ideR ActivePack
                        return ()
                    Nothing -> return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageBuild :: IDEAction
packageBuild = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        ideR        <- ask
        prefs       <- readIDE prefs
        case mbPackage of
            Nothing         -> return ()
            Just package    -> do
                sb <- getSBErrors
                liftIO $statusbarPop sb 1
                liftIO $statusbarPush sb 1 "Building"
                unmarkCurrentError
                pid' <- reifyIDE (\ideR session -> do
                    (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","build"]
                                                    ++ buildFlags package)
                    oid     <-  forkIO (readOut log out)
                    hSetBuffering err NoBuffering
                    eid     <-  forkIO (reflectIDE (readErrForBuild log err) ideR session)
                    return pid)
                when (collectAfterBuild prefs) $ mayRebuildInBackground (Just pid'))
        (\(e :: SomeException) -> putStrLn (show e))

packageDoc :: IDEAction
packageDoc = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $do
                (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","haddock"]
                                                ++ (haddockFlags package))
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageClean :: IDEAction
packageClean = do
    mbPackage   <- getActivePackage
    log         <- getLog
    case mbPackage of
        Nothing         -> return ()
        Just package    -> liftIO $do
            (inp,out,err,pid) <- runExternal "runhaskell" ["Setup","clean"]
            oid <- forkIO (readOut log out)
            eid <- forkIO (readErr log err)
            return ()

packageCopy :: IDEAction
packageCopy = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        mbDir       <- chooseDir "Select the target directory"
        case mbDir of
            Nothing -> return ()
            Just fp ->
                case mbPackage of
                    Nothing         -> return ()
                    Just package    -> liftIO $ do
                        (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","copy"]
                                                ++ ["--destdir=" ++ fp])
                        oid <- forkIO (readOut log out)
                        eid <- forkIO (readErr log err)
                        return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageRun :: IDEAction
packageRun = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $do
                pd <- readPackageDescription normal (cabalFile package) >>= return . flattenPackageDescription
                case executables pd of
                    [(Executable name _ _)] -> do
                        let path = "dist/build" </> name </> name
                        (inp,out,err,pid) <- runExternal path (exeFlags package)
                        oid <- forkIO (readOut log out)
                        eid <- forkIO (readErr log err)
                        return ()
                    otherwise -> do
                        sysMessage Normal "no single executable in selected package"
                        return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageInstall :: IDEAction
packageInstall = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $ do
                (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","install"]
                                                ++ (installFlags package))
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageRegister :: IDEAction
packageRegister = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $do
                (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","register"]
                                                ++ (registerFlags package))
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageUnregister :: IDEAction
packageUnregister = catchIDE (do
    mbPackage   <- getActivePackage
    log         <- getLog
    case mbPackage of
        Nothing         -> return ()
        Just package    -> liftIO $do
            (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","unregister"]
                                            ++ (unregisterFlags package))
            oid <- forkIO (readOut log out)
            eid <- forkIO (readErr log err)
            return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageTest :: IDEAction
packageTest = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $do
                (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","test"])
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageSdist :: IDEAction
packageSdist = catchIDE (do
        mbPackage   <- getActivePackage
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    -> liftIO $do
                (inp,out,err,pid) <- runExternal "runhaskell" (["Setup","sdist"]
                                                ++ (sdistFlags package))
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))


packageOpenDoc :: IDEAction
packageOpenDoc = catchIDE (do
        mbPackage   <- getActivePackage
        prefs       <- readIDE prefs
        log         <- getLog
        case mbPackage of
            Nothing         -> return ()
            Just package    ->
                let path = dropFileName (cabalFile package)
                                </> "dist/doc/html"
                                </> display (pkgName (packageId package))
                                </> display (pkgName (packageId package))
                                </> "index.html"
                in liftIO $do
                (inp,out,err,pid) <- runExternal (browser prefs) [path]
                oid <- forkIO (readOut log out)
                eid <- forkIO (readErr log err)
                return ())
        (\(e :: SomeException) -> putStrLn (show e))


chooseDir :: String -> IDEM (Maybe FilePath)
chooseDir str = do
    win <- readIDE window
    liftIO $do
        dialog <- fileChooserDialogNew
                        (Just $ str)
                        (Just win)
                    FileChooserActionSelectFolder
                    [("gtk-cancel"
                    ,ResponseCancel)
                    ,("gtk-open"
                    ,ResponseAccept)]
        widgetShow dialog
        response <- dialogRun dialog
        case response of
            ResponseAccept -> do
                fn <- fileChooserGetFilename dialog
                widgetDestroy dialog
                return fn
            ResponseCancel -> do
                widgetDestroy dialog
                return Nothing
            ResponseDeleteEvent -> do
                widgetDestroy dialog
                return Nothing
            _ -> return Nothing


-- ---------------------------------------------------------------------
-- | Handling of Compiler errors
--

readErrForBuild :: IDELog -> Handle -> IDEAction
readErrForBuild log hndl = do
    ideRef <- ask
    errs <- liftIO $readAndShow False []
    modifyIDE_ (\ide -> return (ide{errors = reverse errs, currentErr = Nothing}))
    triggerEvent ideRef (Sensitivity [(SensitivityError,not (null errs))])
    sb <- getSBErrors
    let errorNum    =   length (filter isError errs)
    let warnNum     =   length errs - errorNum
    liftIO $statusbarPop sb 1
    liftIO $statusbarPush sb 1 $show errorNum ++ " Errors, " ++ show warnNum ++ " Warnings"
    when (not (null errs)) nextError
    where
    readAndShow :: Bool -> [ErrorSpec] -> IO [ErrorSpec]
    readAndShow inError errs = catch (do
        line    <-  hGetLine hndl
        let parsed  =  parse buildLineParser "" line
        lineNr  <-  appendLog log (line ++ "\n") ErrorTag
        case (parsed, errs) of
            (Left e,_) -> do
                sysMessage Normal (show e)
                readAndShow False errs
            (Right ne@(ErrorLine fp l c str),_) ->
                readAndShow True ((ErrorSpec fp l c str (lineNr,lineNr) True):errs)
            (Right (OtherLine str1),(ErrorSpec fp i1 i2 str (l1,l2) isError):tl) ->
                if inError
                    then readAndShow True ((ErrorSpec fp i1 i2
                                            (if null str
                                                then line
                                                else str ++ "\n" ++ line)
                                            (l1,lineNr) isError) : tl)
                    else readAndShow False errs
            (Right (WarningLine str1),(ErrorSpec fp i1 i2 str (l1,l2) isError):tl) ->
                if inError
                    then readAndShow True ((ErrorSpec fp i1 i2
                                            (if null str
                                                then line
                                                else str ++ "\n" ++ line)
                                            (l1,lineNr) False) : tl)
                    else readAndShow False errs
            otherwise -> readAndShow False errs)
        (\ (_ :: SomeException) -> do
            hClose hndl
            return errs)

selectErr :: Int -> IDEAction
selectErr index = do
    errors <- readIDE errors
    if length errors < index + 1
        then return ()
        else do
            let thisErr = errors !! index
            succ <- selectSourceBuf (filePath thisErr)
            if isJust succ
                then markErrorInSourceBuf (line thisErr) (column thisErr)
                        (errDescription thisErr)
                else return ()
            log :: IDELog <- getLog
            liftIO $ markErrorInLog log (logLines thisErr)

unmarkCurrentError :: IDEAction
unmarkCurrentError = do
    currentErr'     <-  readIDE currentErr
    errors'         <-  readIDE errors
    when (isJust currentErr') $ do
        let theError =  errors' !! fromJust currentErr'
        allBufs     <-  allBuffers
        fpc         <-  liftIO $ canonicalizePath $ filePath theError
        let theBufs =   filter (\ buf -> isJust (fileName buf) &&
                                            equalFilePath fpc (fromJust (fileName buf)))
                            allBufs
        mapM_ removeMark theBufs
        where
        removeMark buf = liftIO $ do
            gtkbuf  <-  textViewGetBuffer (sourceView buf)
            i1      <-  textBufferGetStartIter gtkbuf
            i2      <-  textBufferGetEndIter gtkbuf
            textBufferRemoveTagByName gtkbuf "activeErr" i1 i2

nextError :: IDEAction
nextError = do
    errs <- readIDE errors
    currentErr <- readIDE currentErr
    if null errs
        then return ()
        else do
            case currentErr of
                Nothing -> do
                    modifyIDE_ (\ide -> return (ide{currentErr = Just 0}))
                    selectErr 0
                Just n | (n + 1) < length errs -> do
                    modifyIDE_ (\ide -> return (ide{currentErr = Just (n + 1)}))
                    selectErr (n + 1)
                Just n  -> selectErr n

previousError :: IDEAction
previousError = do
    errs <- readIDE errors
    currentErr <- readIDE currentErr
    if null errs
        then return ()
        else do
            case currentErr of
                Nothing -> do
                    modifyIDE_ (\ide -> return (ide{currentErr = Just (length errs - 1)}))
                    selectErr (length errs - 1)
                Just n | n > 0 -> do
                    modifyIDE_ (\ide -> return (ide{currentErr = Just (n - 1)}))
                    selectErr (n - 1)
                otherwise -> selectErr 0

data BuildError =   BuildLine
                |   EmptyLine
                |   ErrorLine FilePath Int Int String
                |   WarningLine String
                |   OtherLine String

buildLineParser :: CharParser () BuildError
buildLineParser = try (do
        char '['
        integer
        symbol "of"
        integer
        char '['
        many (anyChar)
        return BuildLine)
    <|> try (do
        filePath <- many (noneOf ":")
        char ':'
        line <- integer
        char ':'
        column <- integer
        char ':'
        whiteSpace
        text <- many anyChar
        return (ErrorLine filePath (fromIntegral line) (fromIntegral column) text))
    <|> try (do
        whiteSpace
        eof
        return EmptyLine)
    <|> try (do
        whiteSpace
        symbol "Warning:"
        text <- many anyChar
        return (WarningLine ("Warning:" ++ text)))
    <|> try (do
        text <- many anyChar
        eof
        return (OtherLine text))
    <?> "buildLineParser"


lexer = P.makeTokenParser emptyDef
lexeme = P.lexeme lexer
whiteSpace = P.whiteSpace lexer
hexadecimal = P.hexadecimal lexer
symbol = P.symbol lexer
identifier = P.identifier lexer
colon = P.colon lexer
integer = P.integer lexer

-- ---------------------------------------------------------------------
-- | * Utility functions/procedures, that have to do with packages
--

getPackageDescriptionAndPath :: IDEM (Maybe (PackageDescription,FilePath))
getPackageDescriptionAndPath = do
    active <- readIDE activePack
    case active of
        Nothing -> do
            ideMessage Normal "No active packjage"
            return Nothing
        Just p  -> do
            ideR <- ask
            reifyIDE (\ideR session -> catch (do
                pd <- readPackageDescription normal (cabalFile p)
                return (Just (flattenPackageDescription pd,cabalFile p)))
                    (\(e :: SomeException) -> do
                        reflectIDE (ideMessage Normal ("Can't load package " ++(show e))) ideR session
                        return Nothing))

getModuleTemplate :: PackageDescription -> String -> IO String
getModuleTemplate pd modName = do
    filePath <- getConfigFilePathForLoad "Module.template"
    template <- readFile filePath
    return (foldl' (\ a (from, to) -> replace from to a) template
        [("@License@", (show . license) pd), ("@Maintainer@", maintainer pd),
            ("@Stability@",stability pd), ("@Portability@",""),
                ("@Copyright@", copyright pd),("@ModuleName@", modName)])

addModuleToPackageDescr :: ModuleName -> Bool -> IDEM ()
addModuleToPackageDescr moduleName isExposed = do
    active <- readIDE activePack
    case active of
        Nothing -> do
            ideMessage Normal "No active packjage"
            return ()
        Just p  -> do
            ideR <- ask
            reifyIDE (\ideR session -> catch (do
                gpd <- readPackageDescription normal (cabalFile p)
                if hasConfigs gpd
                    then do
                        reflectIDE (ideMessage High
                            "Cabal File with configurations can't be automatically updated") ideR session
                    else
                        let pd = flattenPackageDescription gpd
                            npd = if isExposed && isJust (library pd)
                                    then pd{library = Just ((fromJust (library pd)){exposedModules =
                                                                    moduleName : exposedModules (fromJust $ library pd)})}
                                    else let npd1 = case library pd of
                                                       Nothing -> pd
                                                       Just lib -> pd{library = Just (lib{libBuildInfo =
                                                                addModToBuildInfo (libBuildInfo lib) moduleName})}
                                         in npd1{executables = map
                                                (\exe -> exe{buildInfo = addModToBuildInfo (buildInfo exe) moduleName})
                                                    (executables npd1)}
                        in writePackageDescription (cabalFile p) npd)
                           (\(e :: SomeException) -> do
                            reflectIDE (ideMessage Normal ("Can't upade package " ++ show e)) ideR session
                            return ()))
    where
    addModToBuildInfo :: BuildInfo -> ModuleName -> BuildInfo
    addModToBuildInfo bi mn = bi {otherModules = mn : otherModules bi}