{-# LANGUAGE RecordWildCards #-}

module TPar.Server
    ( -- * Workers
      Worker
    , localWorker
    , sshWorker
    , runRemoteWorker
      -- * Running the server
    , server
    , runServer
      -- * Convenience wrappers
    , enqueueAndFollow
    ) where

import Control.Error
import Control.Applicative
import Control.Monad (void, forever)
import Data.Foldable
import Data.Traversable
import qualified Data.Heap as H
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.Catch (finally, bracket)
import Control.Distributed.Process hiding (finally, bracket)

import System.IO ( openFile, hClose, IOMode(..))
import System.Exit
import Control.Concurrent.STM

import Pipes
import qualified Pipes.Prelude as PP

import TPar.Rpc
import TPar.RemoteStream as RemoteStream
import TPar.ProcessPipe
import TPar.Server.Types
import TPar.Types
import TPar.JobMatch
import TPar.Utils

-----------------------------------------------
-- Convenience wrappers

enqueueAndFollow :: ServerIface -> JobRequest
                 -> Process (Producer ProcessOutput Process ExitCode)
enqueueAndFollow iface jobReq = do
    (sink, src) <- RemoteStream.newStream
    _jobId <- callRpc (enqueueJob iface) (jobReq, ToRemoteSink sink)
    return $ RemoteStream.toProducer src

-----------------------------------------------
-- Workers

type Worker = JobRequest -> Producer ProcessOutput Process ExitCode

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req) Nothing

sshWorker :: String -> FilePath -> Worker
sshWorker host rootPath req = do
    runProcess "ssh" ([host, "--", "cd", cwd, ";", jobCommand req]++jobArgs req) Nothing
  where
    cwd = rootPath ++ "/" ++ jobCwd req  -- HACK

runRemoteWorker :: ServerIface -> Process ()
runRemoteWorker (ServerIface {..}) = forever runOneJob
  where
    runOneJob = do
        doneVar <- liftIO newEmptyTMVarIO
        -- We run each process in a separate thread to ensure that ProcessKilled
        -- exceptions go to the Process that is actually running the job being
        -- killed
        let finished = liftIO $ atomically $ putTMVar doneVar ()
        _pid <- spawnLocal $ flip finally finished $ do
            (job, finishedSp) <- callRpc requestJob ()
            code <- runJobWithWorker job localWorker
            sendChan finishedSp code

        liftIO $ atomically $ takeTMVar doneVar

runJobWithWorker :: Job -> Worker -> Process ExitCode
runJobWithWorker (Job {..}) worker =
    let intoSink = case jobSink of
                     ToRemoteSink sink -> connectSink sink
                     NoOutput          -> \src -> runEffect $ src >-> PP.drain
                     ToFiles so se     -> \src ->
                         withOutFiles so se $ \hStdout hStderr ->
                         processOutputToHandles hStdout hStderr src
    in intoSink $ worker jobRequest
  where
    withOutFiles outPath errPath action
      | outPath == errPath = withOutFile outPath $ \h -> action h h
      | otherwise          = withOutFile outPath $ \out ->
                             withOutFile errPath $ \err -> action out err
    withOutFile path = bracket (liftIO $ openFile path WriteMode) (liftIO . hClose)

------------------------------------------------
-- the server

-- | Spawn a process running a server
runServer :: Process ServerIface
runServer = do
    q <- liftIO newJobQueue
    iface <- server q
    announce <- spawnLocal $ forever $ do
        x <- expect :: Process (SendPort ServerIface)
        sendChan x iface
    register "tpar" announce
    return iface

-- | The heart of the server
server :: JobQueue -> Process ServerIface
server jobQueue = do
    (enqueueJob, enqueueJobRp) <- newRpc
    (requestJob, requestJobRp) <- newRpc
    (getQueueStatus, getQueueStatusRp) <- newRpc
    (killJobs, killJobsRp) <- newRpc

    serverPid <- spawnLocal $ void $ forever $ do
        serverPid <- getSelfPid
        receiveWait
            [ matchRpc enqueueJobRp $ \(jobReq, dataStream) -> do
                  tparDebug "enqueue"
                  liftIO $ atomically $ do
                      jobId <- getFreshJobId jobQueue
                      queueJob jobQueue jobId dataStream jobReq
                      return (jobId, ())

            , matchRpc' requestJobRp $ \ workerPid () reply -> do
                  tparDebug "request job"
                  spawnLocal $ handleJobRequest serverPid jobQueue workerPid reply
                  return ()

            , matchRpc getQueueStatusRp $ \match -> do
                  q <- liftIO $ atomically $ getJobs jobQueue
                  let filtered = filter (jobMatches match) q
                  return (filtered, ())

            , matchRpc killJobsRp $ \match -> do
                  killedJobs <- handleKillJobs jobQueue match
                  return (killedJobs, ())
            ]
    return $ ServerIface {..}

handleJobRequest :: ProcessId
                 -> JobQueue
                 -> ProcessId
                 -> ((Job, SendPort ExitCode) -> Process ())
                 -> Process ()
handleJobRequest serverPid jobQueue workerPid reply = do
    -- get a job
    link serverPid
    monRef <- monitor workerPid
    job <- liftIO $ atomically $ takeQueuedJob jobQueue

    -- send the job to worker
    (finishedSp, finishedRp) <- newChan
    reply (job, finishedSp)
    let jobid = jobId job
    liftIO $ atomically $ setJobState jobQueue jobid (Running workerPid)
    tparDebug $ "job "++show jobid++" sent"

    -- wait for result
    receiveWait
        [ matchChan finishedRp $ \code -> do
              liftIO $ atomically $ setJobState jobQueue jobid (Finished code)
        , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == monRef) $
          \(ProcessMonitorNotification _ _ reason) -> do
              tparDebug $ "job "++show jobid++" failed"
              liftIO $ atomically $ setJobState jobQueue jobid (Failed $ show reason)
        ]
    unmonitor monRef

handleKillJobs :: JobQueue -> JobMatch -> Process [Job]
handleKillJobs jq@(JobQueue {..}) match = do
    let shouldBeKilled :: Job -> Maybe (Maybe ProcessId, JobId)
        shouldBeKilled job@(Job {..})
          | Running pid <- jobState
          , jobMatches match job    = Just (Just pid, jobId)
          | Queued      <- jobState
          , jobMatches match job    = Just (Nothing, jobId)
          | otherwise               = Nothing
    jobsToKill <- liftIO $ atomically $ mapMaybe shouldBeKilled <$> getJobs jq
    say $ "killing "++show jobsToKill
    killed <- forM jobsToKill $ \(pid, jobid) -> do
        maybe (return ()) (flip exit ProcessKilled) pid
        liftIO $ atomically $ do
            oldState <- updateJob jq jobid $ \job ->
                ( case jobState job of
                    Finished _ -> job
                    _          -> job {jobState=Killed}
                , jobState job
                )
            case oldState of
                Queued    -> do
                    modifyTVar jobQueue $ H.fromList . filter (\(_, job') -> job' /= jobid) . toList
                    return $ Just jobid
                Running _ -> return $ Just jobid
                _         -> return Nothing
    let killedSet = S.fromList $ catMaybes killed
    liftIO $ atomically $ filter (\job -> jobId job `S.member` killedSet) <$> getJobs jq

-----------------------------------------------------
-- primitives

-- | Our job queue state
data JobQueue = JobQueue { freshJobIds :: TVar [JobId]
                         , jobQueue    :: TVar (H.Heap (Priority, JobId))
                         , jobs        :: TVar (M.Map JobId Job)
                         }

getFreshJobId :: JobQueue -> STM JobId
getFreshJobId (JobQueue {..}) = do
    x:xs <- readTVar freshJobIds
    writeTVar freshJobIds xs
    return x

newJobQueue :: IO JobQueue
newJobQueue = JobQueue <$> newTVarIO [ JobId i | i <- [0..] ]
                       <*> newTVarIO H.empty
                       <*> newTVarIO mempty

takeQueuedJob :: JobQueue -> STM Job
takeQueuedJob jq@(JobQueue {..}) = do
    q <- readTVar jobQueue
    case H.viewMin q of
        Nothing -> retry
        Just ((_, jobid), q') -> do
            writeTVar jobQueue q'
            getJob jq jobid

getJob :: JobQueue -> JobId -> STM Job
getJob (JobQueue {..}) jobId = (M.! jobId) <$> readTVar jobs

updateJob :: JobQueue -> JobId -> (Job -> (Job, a)) -> STM a
updateJob (JobQueue {..}) jobId f = do
    jobsMap <- readTVar jobs
    Just x <- pure $ M.lookup jobId jobsMap
    let (x', r) = f x
    writeTVar jobs $ M.insert jobId x' jobsMap
    return r

setJobState :: JobQueue -> JobId -> JobState -> STM ()
setJobState jobQueue jobId newState =
    updateJob jobQueue jobId (\s -> (s {jobState = newState}, ()))

queueJob :: JobQueue -> JobId -> OutputSink -> JobRequest -> STM ()
queueJob (JobQueue {..}) jobId jobSink jobRequest = do
    modifyTVar jobQueue $ H.insert (prio, jobId)
    modifyTVar jobs $ M.insert jobId (Job {jobState = Queued, ..})
  where
    prio = jobPriority jobRequest

getJobs :: JobQueue -> STM [Job]
getJobs (JobQueue {..}) =
    M.elems <$> readTVar jobs
