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

import qualified Data.Aeson as Aeson
import qualified Data.Text as ST
import           Data.Graph
import           Data.Graph.Missing (fixLeaves)
import           Data.Map as Map (toList)
import qualified Data.Tree as Tree (Tree(Node))
import qualified Lucid
import qualified Text.Digestive.Form as DF
import qualified Text.Digestive.Types as DF
import qualified Text.Digestive.Lucid.Html5 as DF

import Access
import Action
    ( ActionM, currentUser, equery, mquery
    , delegateOrWithdraw, delegationInScope
    , currentUserCapCtx
    )
import Data.Delegation (unDelegate, unDelegatee)
import Frontend.Core hiding (form)
import Frontend.Prelude
import Persistent

import qualified Frontend.Path as U


-- | 12. Delegate vote
data PageDelegateVote = PageDelegateVote CapCtx DScopeFull [User] (Maybe (AUID User))
  deriving (Eq, Show, Read)

instance Page PageDelegateVote where isAuthorized = userPage

newtype PageDelegationVotePayload = PageDelegationVotePayload
    { unPageDelegationVotePayload :: Maybe (AUID User) }
  deriving (Eq, Show, Read)

instance FormPage PageDelegateVote where
    type FormPagePayload PageDelegateVote = PageDelegationVotePayload

    formAction (PageDelegateVote _capctx scope _options _mselected) =
        U.createDelegation (fullDScopeToDScope scope)

    redirectOf (PageDelegateVote capCtx scope _options _mselected) _ = case scope of
        DScopeIdeaSpaceFull _ideaSpace -> U.viewUserProfile (capCtx ^. capCtxUser)
        DScopeTopicFull     topic      -> U.viewTopic topic

    makeForm (PageDelegateVote _capCtx _scope options mselected) =
        PageDelegationVotePayload <$>
            "selected-delegate" .: DF.validate valid (DF.text (render <$> mselected))
      where
        render :: AUID User -> ST
        render = ("page-delegate-vote-uid." <>) . cs . show . view unAUID

        -- the error messages here are not translated because they shouldn't be user facing: the
        -- only causes for them are users messing with the page source and programming errors.
        valid :: Monad n => ST -> DF.Result (HtmlT n ()) (Maybe (AUID User))
        valid "" = pure Nothing
        valid (ST.commonPrefixes "page-delegate-vote-uid." -> Just ("page-delegate-vote-uid.", "", s)) =
            Just <$> case readMaybe $ cs s of
                Nothing -> DF.Error ("invalid user id: " <> fromString (show s))
                Just (AUID -> uid)
                  | uid `elem` (view _Id <$> options) -> DF.Success uid
                  | otherwise                         -> DF.Error "user id not found"
        valid bad = DF.Error ("corrupt form data: " <> bad ^. showed . html)

    formPage v f p@(PageDelegateVote _capCtx scope options mselected) = semanticDiv p . f $ do
        let options' = sortBy (maybe compare compareOptions mselected) options

            -- always move selected user to the top.
            compareOptions :: AUID User -> User -> User -> Ordering
            compareOptions uid u1 u2
                | u1 ^. _Id == uid = LT
                | u2 ^. _Id == uid = GT
                | otherwise        = compare (u1 ^. userLogin) (u2 ^. userLogin)

        h1_ [class_ "main-heading"] "Stimme beauftragen"
        div_ [class_ "sub-heading"] $ do
            let delegationText name = "Wähle einen Beauftragten für " <> show name
            toHtml . delegationText $ uilabelST scope
            br_ []
            "Du kannst deine Beauftragung widerrufen, indem du sie nochmal anklickst."
        ul_ $ do
            DF.inputHidden "selected-delegate" v
            div_ [class_ "delegate-image-select"] $ do
                ul_ . for_ options' $ \user -> do
                    let uid = user ^. _Id . unAUID . showed
                        unm = user ^. userLogin . unUserLogin
                    li_ [ class_ "icon-list-button col-3-12"
                          , id_ $ "page-delegate-vote-uid." <> cs uid
                          ] $ do
                        img_ [ src_ . U.TopAvatar . fromString $ uid <> ".png"
                             , alt_ $ user ^. userLogin . unUserLogin
                             ]
                        span_ $ toHtml unm
                div_ [class_ "button-group clearfix"] $ do
                    unless (null options') $
                        DF.inputSubmit "beauftragen"
                    cancelButton p ()

pageDelegateVoteSuccessMsg :: ActionM m => t -> PageDelegationVotePayload -> u -> m ST
pageDelegateVoteSuccessMsg _ (PageDelegationVotePayload Nothing)    _ =
    pure "Deine Beauftragung wurde zurückgenommen."
pageDelegateVoteSuccessMsg _ (PageDelegationVotePayload (Just uid)) _ = do
    delegate <- mquery $ findUser uid
    pure $ "Du hast " <> delegate ^. userLogin . unUserLogin <> " mit Deiner Stimme beauftragt"

delegationEdit :: ActionM m => DScope -> FormPageHandler m PageDelegateVote
delegationEdit scope = formPageHandlerCalcMsgM
    (do delegate <- view delegationTo <$$> delegationInScope scope
        ctx <- currentUserCapCtx
        equery $
            do  scopeFull <- dscopeFull scope
                users <- studentsInDScope scope
                pure $ PageDelegateVote ctx scopeFull users delegate)
    (Action.delegateOrWithdraw scope . unPageDelegationVotePayload)
    pageDelegateVoteSuccessMsg

-- | 13. Delegation network
data PageDelegationNetwork = PageDelegationNetwork DScope DScopeForest DelegationNetwork
  deriving (Eq, Show, Read)

newtype DScopeForest = DScopeForest [Tree DScopeFull]
  deriving (Eq, Show, Read)

instance Aeson.ToJSON DScopeForest where
    toJSON (DScopeForest ts) = Aeson.toJSON $ treeToJSON <$> ts
      where
        treeToJSON (Tree.Node dscope chldrn) = Aeson.object
            [ "dscope"   Aeson..= toUrlPiece (fullDScopeToDScope dscope)
            , "text"     Aeson..= uilabelST dscope
            , "children" Aeson..= (treeToJSON <$> chldrn)
            ]

instance Page PageDelegationNetwork where
    isAuthorized = userPage -- FIXME who needs to see this
    isResponsive _ = False
    extraFooterElems _ = do
        script_ [src_ $ U.TopStatic "third-party/d3/d3.min.js"]
        -- FIXME: move the following two under static-src and sass control, resp.?
        script_ [src_ $ U.TopStatic "d3-aula.js"]
        link_ [rel_ "stylesheet", href_ $ U.TopStatic "d3-aula.css"]

instance ToHtml PageDelegationNetwork where
    toHtml = toHtmlRaw
    toHtmlRaw p@(PageDelegationNetwork dscopeCurrent dscopeForest delegations) = semanticDiv p $ do
        div_ [class_ "container-delagation-network"] $ do
            h1_ [class_ "main-heading"] "Beauftragungsnetzwerk"

            Lucid.script_ $ "var aulaDScopeCurrent  = " <> cs (Aeson.encode (toUrlPiece dscopeCurrent))
            Lucid.script_ $ "var aulaDScopeForest   = " <> cs (Aeson.encode dscopeForest)
            Lucid.script_ $ "var aulaDelegationData = " <> cs (Aeson.encode delegations)

            div_ [class_ "aula-d3-navig"] nil

            div_ $ if null (delegations ^. networkDelegations)
                then do
                    span_ "[Keine Delegationen in diesem Geltungsbereich]"
                else do
                    div_ [class_ "aula-d3-view", id_ "aula-d3-view"] nil

viewDelegationNetwork :: ActionM m  => Maybe DScope -> m PageDelegationNetwork
viewDelegationNetwork (fromMaybe (DScopeIdeaSpace SchoolSpace) -> scope) = do
    user <- currentUser
    equery $ PageDelegationNetwork scope
                <$> (DScopeForest <$> delegationScopeForest user)
                <*> delegationInfos scope

delegationInfos :: DScope -> EQuery DelegationNetwork
delegationInfos scope = do
    delegations <- Map.toList <$> findImplicitDelegationsByScope scope

    -- Create delegations
    let mkGraphNode (de, dees) = (unDelegate de, unDelegate de, unDelegatee . snd <$> dees)

    -- Build graphs and graph handler functions
    let graphNodes = fixLeaves $ mkGraphNode <$> delegations
    let (delegationGraph, _vertexToGraphNode, nodeToVertex) = graphFromEdges graphNodes
    let uidToVertex = fromJust . nodeToVertex
    let graphComponents = stronglyConnComp graphNodes

    -- Count voting power (number of inbound delegation edges in the local 'DScope' and all its
    -- ancestors).
    let mkNode uid = do
            u <- maybe404 =<< findUser uid
            let p = length $ reachable delegationGraph (uidToVertex uid)
            pure (u, p)
    let mkNodeCyclic p uid = do
            u <- maybe404 =<< findUser uid
            pure (u, p)

    users <- concat <$> forM graphComponents (\case
                AcyclicSCC uid  -> (:[]) <$> mkNode uid
                CyclicSCC  []   -> error "delegationInfos: impossible."
                CyclicSCC  (uid:uids) -> do
                    -- Every node in the cycle has the same voting power,
                    -- no need to compute more than once.
                    up@(_u, p) <- mkNode uid
                    (up:) <$> mkNodeCyclic p `mapM` uids)

    -- Convert delegations to the needed form
    let flippedDelegations =
            [ Delegation s (unDelegatee dee) (unDelegate de)
            | (de, dees) <- delegations
            , (s, dee)   <- dees
            ]

    pure $ DelegationNetwork users flippedDelegations
