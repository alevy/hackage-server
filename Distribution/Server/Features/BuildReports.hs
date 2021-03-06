{-# LANGUAGE RankNTypes, NamedFieldPuns, RecordWildCards #-}
module Distribution.Server.Features.BuildReports (
    ReportsFeature(..),
    ReportsResource(..),
    initBuildReportsFeature
  ) where

import Distribution.Server.Framework hiding (BuildLog)

import Distribution.Server.Features.Users
import Distribution.Server.Features.Upload
import Distribution.Server.Features.Core

import Distribution.Server.Features.BuildReports.Backup
import Distribution.Server.Features.BuildReports.State
import qualified Distribution.Server.Features.BuildReports.BuildReport as BuildReport
import Distribution.Server.Features.BuildReports.BuildReport (BuildReport(..))
import Distribution.Server.Features.BuildReports.BuildReports (BuildReports, BuildReportId(..), BuildLog(..))
import qualified Distribution.Server.Framework.ResponseContentTypes as Resource

import Distribution.Server.Packages.Types

import qualified Distribution.Server.Framework.BlobStorage as BlobStorage

import Distribution.Text
import Distribution.Package
import Distribution.Version (Version(..))

import Data.ByteString.Lazy.Char8 (unpack) -- Build reports are ASCII


-- TODO:
-- 1. Put the HTML view for this module in the HTML feature; get rid of the text view
-- 2. Decide build report upload policy (anonymous and authenticated)
data ReportsFeature = ReportsFeature {
    reportsFeatureInterface :: HackageFeature,
    reportsResource :: ReportsResource
}

instance IsHackageFeature ReportsFeature where
    getFeatureInterface = reportsFeatureInterface


data ReportsResource = ReportsResource {
    reportsList :: Resource,
    reportsPage :: Resource,
    reportsLog  :: Resource,
    reportsListUri :: String -> PackageId -> String,
    reportsPageUri :: String -> PackageId -> BuildReportId -> String,
    reportsLogUri  :: PackageId -> BuildReportId -> String
}


initBuildReportsFeature :: String
                        -> ServerEnv
                        -> UserFeature -> UploadFeature
                        -> CoreResource
                        -> IO ReportsFeature
initBuildReportsFeature name env@ServerEnv{serverStateDir} user upload core = do
    reportsState <- reportsStateComponent name serverStateDir
    return $ buildReportsFeature name env user upload core reportsState

reportsStateComponent :: String -> FilePath -> IO (StateComponent AcidState BuildReports)
reportsStateComponent name stateDir = do
  st  <- openLocalStateFrom (stateDir </> "db" </> name) initialBuildReports
  return StateComponent {
      stateDesc    = "Build reports"
    , stateHandle  = st
    , getState     = query st GetBuildReports
    , putState     = update st . ReplaceBuildReports
    , backupState  = dumpBackup
    , restoreState = restoreBackup
    , resetState   = reportsStateComponent name
    }

buildReportsFeature :: String
                    -> ServerEnv
                    -> UserFeature
                    -> UploadFeature
                    -> CoreResource
                    -> StateComponent AcidState BuildReports
                    -> ReportsFeature
buildReportsFeature name
                    ServerEnv{serverBlobStore = store}
                    UserFeature{..} UploadFeature{trusteesGroup}
                    CoreResource{ packageInPath
                                , guardValidPackageId
                                , lookupPackageId
                                , corePackagePage
                                }
                    reportsState
  = ReportsFeature{..}
  where
    reportsFeatureInterface = (emptyHackageFeature name) {
        featureDesc = "Build reports and build logs"
      , featureResources =
          map ($ reportsResource) [
              reportsList
            , reportsPage
            , reportsLog
            ]
      , featureState = [abstractAcidStateComponent reportsState]
      }

    reportsResource = ReportsResource
          { reportsList = (extendResourcePath "/reports/.:format" corePackagePage) {
                resourceDesc = [ (GET, "List available build reports")
                               , (POST, "Upload a new build report")
                               ]
              , resourceGet  = [ ("txt", textPackageReports) ]
              , resourcePost = [ ("",    submitBuildReport) ]
              }
          , reportsPage = (extendResourcePath "/reports/:id.:format" corePackagePage) {
                resourceDesc   = [ (GET, "Get a specific build report")
                                 , (DELETE, "Delete a specific build report")
                                 ]
              , resourceGet    = [ ("txt", textPackageReport) ]
              , resourceDelete = [ ("",    deleteBuildReport) ]
              }
          , reportsLog  = (extendResourcePath "/reports/:id/log" corePackagePage) {
                resourceDesc   = [ (GET, "Get the build log associated with a build report")
                                 , (DELETE, "Delete a build log")
                                 , (PUT, "Upload a build log for a build report")
                                 ]
              , resourceGet    = [ ("txt", serveBuildLog) ]
              , resourceDelete = [ ("",    deleteBuildLog )]
              , resourcePut    = [ ("",    putBuildLog) ]
              }
          , reportsListUri = \format pkgid -> renderResource (reportsList reportsResource) [display pkgid, format]
          , reportsPageUri = \format pkgid repid -> renderResource (reportsPage reportsResource) [display pkgid, display repid, format]
          , reportsLogUri  = \pkgid repid -> renderResource (reportsLog reportsResource) [display pkgid, display repid]
          }

    textPackageReports dpath = do
      pkgid <- packageInPath dpath
      case pkgVersion pkgid of
        Version [] [] -> do
          pkginfo <- lookupPackageId pkgid
          seeOther (reportsListUri reportsResource "" (pkgInfoId pkginfo)) $
            toResponse ()
        _ -> do
          guardValidPackageId pkgid
          reportList <- queryState reportsState $ LookupPackageReports pkgid
          return . toResponse $ show reportList

    textPackageReport dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      (reportId, report, mlog) <- packageReport dpath pkgid
      return . toResponse $ unlines [ "Report #" ++ display reportId, show report
                                    , maybe "No build log" (const "Build log exists") mlog]

    -- result: not-found error or text file
    serveBuildLog :: DynamicPath -> ServerPartE Response
    serveBuildLog dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      (repid, _, mlog) <- packageReport dpath pkgid
      case mlog of
        Nothing -> errNotFound "Log not found" [MText $ "Build log for report " ++ display repid ++ " not found"]
        Just (BuildLog blobId) -> do
            file <- liftIO $ BlobStorage.fetch store blobId
            return . toResponse $ Resource.BuildLog file

    -- result: auth error, not-found error, parse error, or redirect
    submitBuildReport :: DynamicPath -> ServerPartE Response
    submitBuildReport dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      guardAuthorised_ [AnyKnownUser] -- allow any logged-in user
      reportbody <- expectTextPlain
      case BuildReport.parse $ unpack reportbody of
          Left err -> errBadRequest "Error submitting report" [MText err]
          Right report -> do
              reportId <- updateState reportsState $ AddReport pkgid (report, Nothing)
              -- redirect to new reports page
              seeOther (reportsPageUri reportsResource "" pkgid reportId) $ toResponse ()

    {-
      Example using curl:

        curl -u admin:admin \
             -X POST \
             -H "Content-Type: text/plain" \
             --data-binary @reports/nats-0.1 \
             http://localhost:8080/package/nats-0.1/reports/
    -}

    -- result: auth error, not-found error or redirect
    deleteBuildReport :: DynamicPath -> ServerPartE Response
    deleteBuildReport dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      reportId <- reportIdInPath dpath
      guardAuthorised_ [InGroup trusteesGroup]
      success <- updateState reportsState $ DeleteReport pkgid reportId
      if success
          then seeOther (reportsListUri reportsResource "" pkgid) $ toResponse ()
          else errNotFound "Build report not found" [MText $ "Build report #" ++ display reportId ++ " not found"]

    putBuildLog :: DynamicPath -> ServerPartE Response
    putBuildLog dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      reportId <- reportIdInPath dpath
      -- logged in users
      guardAuthorised_ [AnyKnownUser]
      blogbody <- expectTextPlain
      buildLog <- liftIO $ BlobStorage.add store blogbody
      void $ updateState reportsState $ SetBuildLog pkgid reportId (Just $ BuildLog buildLog)
      noContent (toResponse ())

    {-
      Example using curl: (TODO: why is this PUT, while logs are POST?)

        curl -u admin:admin \
             -X PUT \
             -H "Content-Type: text/plain" \
             --data-binary @logs/nats-0.1 \
             http://localhost:8080/package/nats-0.1/reports/1/log
    -}

    deleteBuildLog :: DynamicPath -> ServerPartE Response
    deleteBuildLog dpath = do
      pkgid <- packageInPath dpath
      guardValidPackageId pkgid
      reportId <- reportIdInPath dpath
      guardAuthorised_ [InGroup trusteesGroup]
      void $ updateState reportsState $ SetBuildLog pkgid reportId Nothing
      noContent (toResponse ())

    ---------------------------------------------------------------------------

    reportIdInPath :: MonadPlus m => DynamicPath -> m BuildReportId
    reportIdInPath dpath = maybe mzero return (simpleParse =<< lookup "id" dpath)

    packageReport :: DynamicPath -> PackageId -> ServerPartE (BuildReportId, BuildReport, Maybe BuildLog)
    packageReport dpath pkgid = do
      reportId <- reportIdInPath dpath
      mreport  <- queryState reportsState $ LookupReport pkgid reportId
      case mreport of
        Nothing -> errNotFound "Report not found" [MText "Build report does not exist"]
        Just (report, mlog) -> return (reportId, report, mlog)

