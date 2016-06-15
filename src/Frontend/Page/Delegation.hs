{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE ViewPatterns        #-}

{-# OPTIONS_GHC -Werror -Wall #-}

module Frontend.Page.Delegation
where

import Prelude
import Control.Arrow ((&&&))

import qualified Text.Digestive.Form as DF
import qualified Text.Digestive.Lucid.Html5 as DF

import Access
import Action (ActionM, currentUser, delegateTo, equery)
import Frontend.Core hiding (form)
import Frontend.Prelude
import Persistent

import qualified Frontend.Path as U

import qualified Data.Map as Map
import qualified Data.Set as Set
import           Data.Tree (Tree)
import qualified Data.Tree as Tree (flatten)

-- | 12. Delegate vote
data PageDelegateVote = PageDelegateVote (Either Topic Idea) [User]
  deriving (Eq, Show, Read)

instance Page PageDelegateVote where isAuthorized = userPage

newtype PageDelegationVotePayload = PageDelegationVotePayload
    { unPageDelegationVotePayload :: AUID User }
  deriving (Eq, Show, Read)

instance FormPage PageDelegateVote where
    type FormPagePayload PageDelegateVote = PageDelegationVotePayload

    formAction (PageDelegateVote scope _users) = case scope of
        Left  topic  -> U.delegateVoteOnTopic topic
        Right idea   -> U.delegateVoteOnIdea idea

    redirectOf (PageDelegateVote scope _users) _ = case scope of
        Left  topic  -> U.viewTopic topic
        Right idea   -> U.viewIdea idea

    -- TODO: Show the existing delegation
    makeForm (PageDelegateVote _scope users) =
        PageDelegationVotePayload
        <$> "user-to-delegate" .: DF.choice userList Nothing
      where
        userList = (view _Id &&& view (userLogin . unUserLogin . html)) <$> users

    formPage v f p@(PageDelegateVote _scope _users) = semanticDiv p . f $ do
        -- TODO: Table from users
        DF.inputSelect "user-to-delegate" v
        DF.inputSubmit "beauftragen"
        -- TODO: Cancel button

ideaDelegation :: ActionM m => AUID Idea -> FormPageHandler m PageDelegateVote
ideaDelegation iid = formPageHandlerWithMsg
    (equery $
        do idea <- maybe404 =<< findIdea iid
           users <- usersForIdeaSpace (idea ^. ideaLocation . ideaLocationSpace)
           pure $ PageDelegateVote (Right idea) users)
    (Action.delegateTo (DScopeIdeaId iid) . unPageDelegationVotePayload)
    "Beauftragung erfolgt"

topicDelegation :: ActionM m => AUID Topic -> FormPageHandler m PageDelegateVote
topicDelegation tid = formPageHandlerWithMsg
    (equery $
        do topic <- maybe404 =<< findTopic tid
           users <- usersForIdeaSpace (topic ^. topicIdeaSpace)
           pure $ PageDelegateVote (Left topic) users)
    (Action.delegateTo (DScopeTopicId tid) . unPageDelegationVotePayload)
    "Beauftragung erfolgt"

-- | 13. Delegation network
data PageDelegationNetwork = PageDelegationNetwork DScope (Tree DScopeFull) [DelegationInfo]
  deriving (Eq, Show, Read)

data PageDelegationNetworkPayload = PageDelegationNetworkPayload DScope
  deriving (Eq, Show)

instance Page PageDelegationNetwork where
    isAuthorized = userPage -- FIXME who needs to see this
    extraFooterElems _ = do
        script_ [src_ $ U.TopStatic "third-party/d3/d3.js"]
        script_ [src_ $ U.TopStatic "d3-aula.js"]
        link_ [rel_ "stylesheet", href_ $ U.TopStatic "d3-aula.css"]

{-
        let bigHr = do
              hr_ []
              br_ []
              hr_ []

        bigHr

        let delegationLevels = div_ $ do
                br_ []
                "  Ebene  "
                select_ [name_ "level"] $ do
                    option_ "Schule"
                    option_ [selected_ "selected"] "Klasse 5f"
                    option_ "Thema"
                    option_ "Idee"

                br_ []
                "  Thema  "
                select_ [name_ "topic"] $ do
                    option_ [selected_ "selected"] "Thema 'Kantinenessen'"
                    option_ [selected_ "selected"] "Thema 'Schulhofmöbel'"
                    option_ [selected_ "selected"] "Thema 'Saunabereich'"

                br_ []
                "  Idee  "
                select_ [name_ "idea"] $ do
                    option_ [selected_ "selected"] "Idee '1'"
                    option_ [selected_ "selected"] "Idee '2'"
                    option_ [selected_ "selected"] "Idee '3'"
                    option_ [selected_ "selected"] "Idee '4'"
                    option_ [selected_ "selected"] "Idee '5'"
                    option_ [selected_ "selected"] "Idee '6'"
                    option_ [selected_ "selected"] "Idee '7'"
                    option_ [selected_ "selected"] "Idee '8'"
                    option_ [selected_ "selected"] "Idee '9'"

        div_ $ do

            br_ []
            table_ $ do
                tr_ $ do
                    th_ "[angezeigte ebene]"
                    th_ "[angezeigte schüler]"
                    th_ "[weggeblendete schüler]"
                    th_ "[das netzwerk]"
                tr_ $ do
                    td_ delegationLevels
                    td_ . ul_ $ li_ `mapM_` ["Hannah", "Hanna", "Leonie", "Leoni", "Lea", "Leah", "Lena"]
                    td_ . ul_ $ li_ `mapM_` ["Sara", "Emma", "Lilli", "Lilly", "Lili", "Marie", "Lina",
                                             "Maja", "Maya", "Johanna", "Sophie", "Sofie", "Nele", "Neele",
                                             "Sophia", "Sofia", "Amelie", "Lisa", "Leni", "Julia", "Alina"]
                    td_ $ span_ [id_ "d3"] nil

        bigHr
-}

instance FormPage PageDelegationNetwork where
    type FormPagePayload PageDelegationNetwork = PageDelegationNetworkPayload
    type FormPageResult  PageDelegationNetwork = PageDelegationNetworkPayload

    formAction (PageDelegationNetwork scope _ _)      = U.delegationViewScope scope
    redirectOf _ (PageDelegationNetworkPayload scope) = U.delegationViewScope scope

    makeForm (PageDelegationNetwork actualDScope dscopes _delegations) =
        PageDelegationNetworkPayload
        <$> ("scope" .: DF.choice delegationScopeList (Just actualDScope))
      where
        delegationScopeList = (fullDScopeToDScope &&& uilabel) <$> Tree.flatten dscopes

    formPage v form p@(PageDelegationNetwork _ _ delegations) = semanticDiv p $ do
        form $ do
            inputSelect_ [] "scope" v
            DF.inputSubmit "Show delegations!"
            p_ . toHtml $ show delegations
            img_ [src_ . U.TopStatic $ "images" </> "delegation_network_dummy.jpg"]

viewDelegationNetwork :: ActionM m => Maybe DScope -> FormPageHandler m PageDelegationNetwork
viewDelegationNetwork (fromMaybe DScopeGlobal -> scope) = formPageHandler
    (do user <- currentUser
        equery $ PageDelegationNetwork scope
                    <$> delegationScopeTree user
                    <*> delegationInfos scope)
    pure

delegationInfos :: DScope -> EQuery [DelegationInfo]
delegationInfos scope = do
    delegations <- findDelegationsByScope scope
    let users = Set.toList . Set.fromList
                $ (\d -> [d ^. delegationFrom, d ^. delegationTo]) =<< delegations
    userMap <- Map.fromList . catMaybes
               <$> forM users (\userId -> (,) userId <$$> findUser userId)
    (pure . catMaybes). flip map delegations $ \d ->
            DelegationInfo <$> Map.lookup (d ^. delegationFrom) userMap
                           <*> Map.lookup (d ^. delegationTo)   userMap
