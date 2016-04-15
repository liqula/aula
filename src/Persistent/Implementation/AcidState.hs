{-# LANGUAGE ConstraintKinds             #-}
{-# LANGUAGE FlexibleContexts            #-}
{-# LANGUAGE GADTs                       #-}
{-# LANGUAGE ImpredicativeTypes          #-}
{-# LANGUAGE MultiParamTypeClasses       #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TupleSections               #-}
{-# LANGUAGE TypeFamilies                #-}
{-# LANGUAGE TypeOperators               #-}

-- {-# OPTIONS_GHC -Wall -Werror -fno-warn-orphans #-}

module Persistent.Implementation.AcidState
    ( mkRunPersistOnDisk
    , mkRunPersistInMemory
    , AcidState
    )
where

import Control.Concurrent
import Control.Exception hiding (handle)
import Control.Lens
import Control.Monad
import Data.Acid
import Data.Acid.Local (createCheckpointAndClose)
import Data.Acid.Memory (openMemoryState)
import Data.Monoid ((<>))

import Config
import Persistent.Pure
import Persistent.Api


mkRunPersistGeneric :: String
                    -> (AulaData -> IO (AcidState AulaData, a))
                    -> (AcidState AulaData -> a -> IO ())
                    -> IO RunPersist
mkRunPersistGeneric desc openState closeState = do
    (st, handle) <- openState emptyAulaData
    pure RunPersist { _rpDesc   = desc
                    , _rpQuery  = query st AskDb
                    , _rpUpdate = update st
                    , _rpClose  = closeState st handle
                    }

mkRunPersistOnDisk :: Config -> IO RunPersist
mkRunPersistOnDisk cfg =
    mkRunPersistGeneric "acid-state (disk)" opn cls
  where
    opn aulaData = do
        st <- openLocalStateFrom (cfg ^. persistConfig . dbPath) aulaData
        tid <- forkIO . forever $ do
            let run = do
                    logger cfg "[create acid-state checkpoint, archive]"
                    createCheckpoint st
                    createArchive st

                catchAll (SomeException e) = do
                    logger cfg ("error creating checkpoint or archiving changelog: " <> show e)

                delay_min = cfg ^. persistConfig . snapshotIntervalMinutes
                delay_us = delay_min * 1000000 * 60

            run `catch` catchAll
            threadDelay delay_us

        pure (st, tid)

    cls st tid = do
        killThread tid
        createCheckpointAndClose st

mkRunPersistInMemory :: IO RunPersist
mkRunPersistInMemory =
    mkRunPersistGeneric "acid-state (memory)"
        (fmap (, ()) . openMemoryState)
        (\st () -> closeAcidState st)
