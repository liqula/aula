{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -Werror -Wall #-}

module Frontend.Page.Idea
  ( ViewIdea(..)
  , CreateIdea(..)
  , EditIdea(..)
  , CommentIdea(..)   -- FIXME: rename to 'CommentOnIdea'
  , JudgeIdea(..)
  , CreatorStatement(..)
  , viewIdea
  , createIdea
  , editIdea
  , commentIdea       -- FIXME: rename to 'commentOnIdea'
  , replyCommentIdea  -- FIXME: rename to 'commentOnComment'
  , judgeIdea
  , creatorStatement
  )
where

import Action ( ActionM, ActionPersist, ActionUserHandler, ActionExcept
              , currentUserAddDb, equery, mquery, update
              , markIdeaInJuryPhase
              , setCreatorStatement
              )
import LifeCycle
import Frontend.Fragment.Category
import Frontend.Fragment.Comment
import Frontend.Fragment.Feasibility
import Frontend.Fragment.QuorumBar
import Frontend.Prelude hiding ((<|>), editIdea)
import Frontend.Validation
import Persistent.Api hiding (EditIdea)

import qualified Action (createIdea)
import qualified Data.Map as Map
import qualified Frontend.Path as U
import qualified Persistent.Api as Persistent
import qualified Text.Digestive.Form as DF
import qualified Text.Digestive.Lucid.Html5 as DF


-- * types

-- | 5 Idea detail page
-- This includes the pages 5.1 to 5.7 excluding 5.5 (PageIdeaDetailMoveIdeaToTopic) which needs its
-- own endpoint.
--
-- * 5.1 Idea detail page: New ideas
-- * 5.2 Idea detail page: Refinement phase
-- * 5.3 Idea detail page: Jury (assessment) phase
-- * 5.4 Idea detail page: Voting phase
-- * 5.6 Idea detail page: Feasible / not feasible
-- * 5.7 Idea detail page: Winner
data ViewIdea = ViewIdea RenderContext ListInfoForIdea
  deriving (Eq, Show, Read)

instance Page ViewIdea where

-- | 6. Create idea
data CreateIdea = CreateIdea IdeaLocation
  deriving (Eq, Show, Read)

instance Page CreateIdea where

-- | 7. Edit idea
data EditIdea = EditIdea Idea
  deriving (Eq, Show, Read)

instance Page EditIdea where

-- | X. Comment idea
data CommentIdea = CommentIdea Idea (Maybe Comment)
  deriving (Eq, Show, Read)

instance Page CommentIdea where

-- | X. Deem idea feasible / not feasible
-- Assumption: The idea is located in the topic (via 'IdeaLocation').
data JudgeIdea = JudgeIdea IdeaJuryResultType Idea Topic
  deriving (Eq, Show, Read)

instance Page JudgeIdea where

data CreatorStatement = CreatorStatement Idea
  deriving (Eq, Show, Read)

instance Page CreatorStatement where

-- ** non-page types

data IdeaVoteLikeBars = IdeaVoteLikeBars [IdeaCapability] ViewIdea
  deriving (Eq, Show, Read)


-- * templates

backLink :: Monad m => IdeaLocation -> HtmlT m ()
backLink IdeaLocationSpace{} = "Zum Ideenraum"
backLink IdeaLocationTopic{} = "Zum Thema"

numberWithUnit :: Monad m => Int -> ST -> ST -> HtmlT m ()
numberWithUnit i singular_ plural_ =
    toHtml (show i) <>
    toHtmlRaw nbsp <>
    toHtml (if i == 1 then singular_ else plural_)

instance ToHtml ViewIdea where
    toHtmlRaw = toHtml
    toHtml p@(ViewIdea ctx (ListInfoForIdea idea phase _quo _voters)) = semanticDiv p $ do
        let totalLikes    = Map.size $ idea ^. ideaLikes
            totalVotes    = Map.size $ idea ^. ideaVotes
            totalComments = idea ^. ideaComments . commentsCount
            uid           = ctx ^. renderContextUser . _Id
            role          = ctx ^. renderContextUser . userRole
            caps          = ideaCapabilities uid role idea phase

        div_ [class_ "hero-unit narrow-container"] $ do
            header_ [class_ "detail-header"] $ do
                a_ [ class_ "btn m-back detail-header-back"
                   , href_ . U.listIdeas $ idea ^. ideaLocation
                   ] $ backLink (idea ^. ideaLocation)

                when (any (`elem` caps) [CanEdit, CanMoveBetweenTopics]) $ do
                    nav_ [class_ "pop-menu m-dots detail-header-menu"] $ do
                        ul_ [class_ "pop-menu-list"] $ do
                            li_ [class_ "pop-menu-list-item"] $ do
                                when (CanEdit `elem` caps) . a_ [href_ $ U.editIdea idea] $ do
                                    i_ [class_ "icon-pencil"] nil
                                    "bearbeiten"
                                when (CanMoveBetweenTopics `elem` caps) . a_ [href_ U.Broken] $ do
                                    i_ [class_ "icon-sign-out"] nil
                                    "Idee verschieben"

            h1_ [class_ "main-heading"] $ idea ^. ideaTitle . html
            div_ [class_ "sub-header meta-text"] $ do
                "von "
                a_ [ href_ $ U.User (idea ^. createdBy) U.UserIdeas
                   ] $ idea ^. createdByLogin . unUserLogin . html
                " / "
                let l = do
                        numberWithUnit totalLikes "Like" "Likes"
                        toHtmlRaw (" " <> nbsp <> " / " <> nbsp <> " ")  -- FIXME: html?
                    v = do
                        numberWithUnit totalVotes "Stimme" "Stimmen"
                        toHtmlRaw (" " <> nbsp <> " / " <> nbsp <> " ")  -- FIXME: html?
                    c = do
                        numberWithUnit totalComments "Verbesserungsvorschlag" "Verbesserungsvorschläge"

                case phase of
                    PhaseWildIdea     -> l >> c
                    PhaseWildFrozen   -> l >> c
                    PhaseRefinement{} -> c
                    PhaseRefFrozen{}  -> c
                    PhaseJury         -> c
                    PhaseVoting{}     -> v >> c
                    PhaseVotFrozen{}  -> v >> c
                    PhaseResult       -> v >> c

            div_ [class_ "sub-heading"] $ do
                toHtml $ IdeaVoteLikeBars caps p

            feasibilityVerdict True idea caps

            -- creator statement
            when (CanAddCreatorStatement `elem` caps) $ do
                div_ [class_ "creator-statement-button"] $ do
                    button_ [ class_ "btn-cta m-valid"
                            , onclick_ $ U.creatorStatement idea
                            ] $ do
                        i_ [class_ "icon-check"] nil
                        if isNothing $ creatorStatementOfIdea idea
                            then "Statement abgeben"
                            else "Statement ändern"

            mapM_
                (div_ [class_ "creator-statement"] . view html)
                (creatorStatementOfIdea idea)

            -- mark winning idea
            -- FIXME: Styling
            when (isFeasibleIdea idea) $ do
                div_ [class_ "winning-idea"] $ do
                    when (CanMarkWinner `elem` caps) $ do
                        let winnerButton =
                                postButton_
                                    [class_ "btn-cta mark-winner-button"
                                    , onclickJs jsReloadOnClick
                                    ]

                        when (isNothing (idea ^. ideaVoteResult)) $
                            winnerButton (U.markWinnerIdea idea) "Idee hat gewonnen"
                        when (isWinning idea) $
                            winnerButton (U.revokeWinnerIdea idea) "\"gewonnen\" zurücknehmen"

                    when (isWinning idea) $
                        div_ [class_ "btn-cta"] "gewonnen"
                    -- FIXME: Add information about not enough votes.

        -- article
        div_ [class_ "container-narrow text-markdown"] $ do
            idea ^. ideaDesc . html

            div_ [class_ "view-category"] $ do
                case idea ^. ideaCategory of
                    Nothing -> do
                        h2_ [class_ "sub-header"] "Diese Idee gehört zu keiner Kategorie"
                    Just cat -> do
                        h2_ [class_ "sub-header"] "Diese Idee gehört zur Kategorie"
                        div_ [class_ "icon-list m-inline"] .
                            ul_ . toHtml $ CategoryLabel cat

        -- comments
        section_ [class_ "comments"] $ do
            header_ [class_ "comments-header"] $ do
                div_ [class_ "grid"] $ do
                    div_ [class_ "container-narrow"] $ do
                        h2_ [class_ "comments-header-heading"] $ do
                            numberWithUnit totalComments
                                "Verbesserungsvorschlag" "Verbesserungsvorschläge"
                        when (CanComment `elem` caps) $
                            button_ [ value_ "create_comment"
                                    , class_ "btn-cta comments-header-button"
                                    , onclick_ (U.commentIdea idea)]
                                "Neuer Verbesserungsvorschlag"
            div_ [class_ "comments-body grid"] $ do
                div_ [class_ "container-narrow"] $ do
                    for_ (idea ^. ideaComments) $ \c ->
                        CommentWidget ctx caps c ^. html


instance ToHtml IdeaVoteLikeBars where
    toHtmlRaw = toHtml
    toHtml p@(IdeaVoteLikeBars caps
                (ViewIdea ctx (ListInfoForIdea idea phase quo voters))) = semanticDiv p $ do
        let likeBar :: Html () -> Html ()
            likeBar bs = div_ $ do
                toHtml (QuorumBar $ percentLikes idea quo)
                span_ [class_ "like-bar"] $ do
                    toHtml (show (numLikes idea) <> " von " <> show quo <> " Quorum-Stimmen")
                bs

            likeButtons :: Html ()
            likeButtons = if CanLike `elem` caps
                then div_ [class_ "voting-buttons"] $
                        postButton_ [ class_ "btn"
                                    , onclickJs . jsReloadOnClickAnchor $ U.anchor (idea ^. _Id)
                                    ]
                                    (U.likeIdea idea)
                            "dafür!"
                        -- FIXME: how do you un-like an idea?
                else nil

            voteBar :: Html () -> Html ()
            voteBar bs = div_ [class_ "voting-widget"] $ do
                span_ [class_ "progress-bar m-show-abstain"] $ do
                    span_ [class_ "progress-bar-row"] $ do
                        span_ [ class_ "progress-bar-progress progress-bar-progress-for"
                              , style_ . cs $ concat ["width: ", yesPercent, "%"]
                              ] $ do
                            span_ [class_ "votes"] yesVotes
                        span_ [ class_ "progress-bar-progress progress-bar-progress-against"
                              , style_ . cs $ concat ["width: ", noPercent, "%"]
                              ] $ do
                            span_ [class_ "votes"] noVotes
                        span_ [ class_ "progress-bar-progress progress-bar-progress-abstain"] $ do
                            span_ [class_ "votes"] $ voters ^. showed . html
                bs
              where
                yesVotes    = numVotes idea Yes ^. showed . html
                noVotes     = numVotes idea No  ^. showed . html
                yesPercent  = max (percentVotes idea voters Yes) 5 ^. showed
                noPercent   = max (percentVotes idea voters No)  5 ^. showed

            user = ctx ^. renderContextUser

            voteButtons :: Html ()
            voteButtons = if CanVote `elem` caps
                then div_ [class_ "voting-buttons"] $ do
                    voteButton vote Yes "dafür"
                    voteButton vote No  "dagegen"
                else nil
              where
                vote = userVoteOnIdea user idea

            -- FIXME: The button for the selected vote value is white.
            -- Should it be in other color?
            voteButton (Just w) v | w == v =
                postButton_ [class_ "btn voting-button"
                            , onclickJs jsReloadOnClick
                            ]
                            (U.removeVote idea user)
            voteButton _        v =
                postButton_ [class_ "btn-cta voting-button"
                            , onclickJs jsReloadOnClick
                            ]
                            (U.voteIdea idea v)

        case phase of
            PhaseWildIdea     -> toHtml $ likeBar likeButtons
            PhaseWildFrozen   -> toHtml $ likeBar nil
            PhaseRefinement{} -> nil
            PhaseRefFrozen{}  -> nil
            PhaseJury         -> nil
            PhaseVoting{}     -> toHtml $ voteBar voteButtons
            PhaseVotFrozen{}  -> toHtml $ voteBar nil
            PhaseResult       -> toHtml $ voteBar nil

validateIdeaTitle :: CSFormTransformer m r s
validateIdeaTitle = validate "Titel der Idee" title

instance FormPage CreateIdea where
    type FormPagePayload CreateIdea = ProtoIdea
    type FormPageResult CreateIdea = Idea

    formAction (CreateIdea loc) = U.createIdea loc

    redirectOf (CreateIdea _loc) = U.viewIdea

    makeForm (CreateIdea loc) =
        ProtoIdea
        <$> ("title"         .: validateIdeaTitle (DF.text Nothing))
        <*> ("idea-text"     .: validateMarkdown "Idee" (DF.string Nothing))
        <*> ("idea-category" .: makeFormSelectCategory Nothing)
        <*> pure loc

    formPage v form p@(CreateIdea iloc) = createOrEditPage False iloc v form p

instance FormPage EditIdea where
    type FormPagePayload EditIdea = ProtoIdea

    formAction (EditIdea idea) = U.editIdea idea

    redirectOf (EditIdea idea) _ = U.viewIdea idea

    makeForm (EditIdea idea) =
        ProtoIdea
        <$> ("title"         .: validateIdeaTitle (DF.text . Just $ idea ^. ideaTitle))
        <*> ("idea-text"     .: validateMarkdown "Idee" (DF.string . Just . cs . unMarkdown $ idea ^. ideaDesc))
        <*> ("idea-category" .: makeFormSelectCategory (idea ^. ideaCategory))
        <*> pure (idea ^. ideaLocation)

    formPage v form p@(EditIdea idea) = createOrEditPage True (idea ^. ideaLocation) v form p

createOrEditPage :: (Monad m, Typeable page, Page page) =>
    Bool -> IdeaLocation ->
    View (HtmlT m ()) -> (HtmlT m () -> HtmlT m ()) -> page -> HtmlT m ()
createOrEditPage showDeleteButton cancelUrl v form p = semanticDiv p $ do
    div_ [class_ "container-main popup-page"] $ do
        div_ [class_ "container-narrow"] $ do
            h1_ [class_ "main-heading"] "Deine Idee"
            form $ do
                label_ $ do
                    span_ [class_ "label-text"] "Wie soll deine Idee heißen?"
                    inputText_ [class_ "m-small", placeholder_ "z.B. bessere Ausstattung im Computerraum"]
                        "title" v
                label_ $ do
                    span_ [class_ "label-text"] "Was möchtest du vorschlagen?"
                    inputTextArea_ [placeholder_ "Hier kannst du deine Idee so ausführlich wie möglich beschreiben..."]
                        Nothing Nothing "idea-text" v
                formPageSelectCategory v
                footer_ [class_ "form-footer"] $ do
                    DF.inputSubmit "Idee veröffentlichen"
                    a_ [class_ "btn-cta", href_ $ U.listIdeas cancelUrl] $ do
                        -- FIXME: "are you sure?" dialog.
                        i_ [class_ "icon-trash-o"] nil
                        "Idee verwerfen"
                    when showDeleteButton .
                        button_ [class_ "btn-cta", value_ ""] $ do
                            -- FIXME: delete ideas.
                            -- FIXME: "are you sure?" dialog.
                            i_ [class_ "icon-trash-o"] nil
                            "Idee löschen"

instance FormPage CommentIdea where
    type FormPagePayload CommentIdea = CommentContent
    type FormPageResult CommentIdea = Comment

    formAction (CommentIdea idea mcomment) = U.commentOrReplyIdea idea mcomment

    redirectOf (CommentIdea idea _) = U.viewIdeaAtComment idea . view _Id

    makeForm CommentIdea{} =
        "comment-text" .: (CommentContent <$> validateMarkdown "Verbesserungsvorschlag" (DF.string Nothing))

    -- FIXME styling
    formPage v form p@(CommentIdea idea _mcomment) =
        semanticDiv p $ do
            div_ [class_ "container-comment-idea"] $ do
                h1_ [class_ "main-heading"] $ "Verbesserungsvorschlag zu " <> idea ^. ideaTitle . html
                form $ do
                    label_ $ do
                        span_ [class_ "label-text"] "Was möchtest du sagen?"
                        inputTextArea_ [placeholder_ "..."] Nothing Nothing "comment-text" v
                    footer_ [class_ "form-footer"] $ do
                        DF.inputSubmit "Verbesserungsvorschlag abgeben"

instance FormPage JudgeIdea where
    type FormPagePayload JudgeIdea = IdeaJuryResultValue

    formAction (JudgeIdea juryType idea _topic) = U.judgeIdea idea juryType

    redirectOf (JudgeIdea _ _idea topic) _ = U.listTopicIdeas topic
        -- FIXME: we would like to say `U.listTopicIdeas topic </#> U.anchor (idea ^. _Id)` here,
        -- but that requires some refactoring around 'redirectOf'.

    makeForm (JudgeIdea IdeaFeasible _ _) =
        Feasible
        <$> "jury-text" .: validateOptionalMarkdown "Anmerkungen zur Durchführbarkeit" (DF.optionalString Nothing)
    makeForm (JudgeIdea IdeaNotFeasible _ _) =
        NotFeasible
        <$> "jury-text" .: validateMarkdown "Anmerkungen zur Durchführbarkeit" (DF.string Nothing)

    -- FIXME styling
    formPage v form p@(JudgeIdea juryType idea _topic) =
        semanticDiv p $ do
            div_ [class_ "container-jury-idea"] $ do
                h1_ [class_ "main-heading"] $ headerText <> idea ^. ideaTitle . html
                form $ do
                    label_ $ do
                        span_ [class_ "label-text"] $
                            case juryType of
                                IdeaFeasible    -> "Möchten Sie die Idee kommentieren?"
                                IdeaNotFeasible -> "Bitte formulieren Sie eine Begründung!"
                        inputTextArea_ [placeholder_ "..."] Nothing Nothing "jury-text" v
                    footer_ [class_ "form-footer"] $ do
                        DF.inputSubmit "Entscheidung speichern."
      where
        headerText = case juryType of
            IdeaFeasible    -> "[Angenommen zur Wahl] "
            IdeaNotFeasible -> "[Abgelehnt als nicht umsetzbar] "

instance FormPage CreatorStatement where
    type FormPagePayload CreatorStatement = Document
    type FormPageResult CreatorStatement = ()

    formAction (CreatorStatement idea) = U.creatorStatement idea
    redirectOf (CreatorStatement idea) _ = U.viewIdea idea

    makeForm (CreatorStatement idea) =
        "statement-text" .: validateMarkdown "Statement des Autors" (DF.string (cs . unMarkdown <$> creatorStatementOfIdea idea))

    -- FIXME styling
    formPage v form p@(CreatorStatement idea) =
        semanticDiv p $ do
            div_ [class_ "container-creator-statement"] $ do
                h1_ [class_ "main-heading"] $ "Ansage des Gewinners zur Idee " <> idea ^. ideaTitle . html
                form $ do
                    label_ $ do
                        span_ [class_ "label-text"] "Was möchtest du sagen?"
                        inputTextArea_ [placeholder_ "..."] Nothing Nothing "statement-text" v
                    footer_ [class_ "form-footer"] $ do
                        DF.inputSubmit "Abschicken"


-- * handlers

-- | FIXME: 'viewIdea' and 'editIdea' do not take an 'IdeaSpace' or @'AUID' 'Topic'@ param from the
-- uri path, but use the idea location instead.  (this may potentially hide data inconsistencies.
-- on the bright side, it makes shorter uri paths possible.)
viewIdea :: (ActionPersist m, MonadError ActionExcept m, ActionUserHandler m)
    => AUID Idea -> m ViewIdea
viewIdea ideaId = ViewIdea <$> renderContext <*> equery (findIdea ideaId >>= maybe404 >>= getListInfoForIdea)

-- FIXME: ProtoIdea also holds an IdeaLocation, which can introduce inconsistency.
createIdea :: ActionM m => IdeaLocation -> FormPageHandler m CreateIdea
createIdea loc = FormPageHandler (pure $ CreateIdea loc) Action.createIdea

-- | FIXME: there is a race condition if several edits happen concurrently.  this can happen if
-- student and moderator edit an idea at the same time.  One solution would be to carry a
-- 'last-changed' timestamp in the edit form, and check for it before writing the edits.
editIdea :: ActionM m => AUID Idea -> FormPageHandler m EditIdea
editIdea ideaId =
    FormPageHandler
        (EditIdea <$> mquery (findIdea ideaId))
        (update . Persistent.EditIdea ideaId)

commentIdea :: ActionM m => IdeaLocation -> AUID Idea -> FormPageHandler m CommentIdea
commentIdea loc ideaId =
    FormPageHandler
        (CommentIdea <$> mquery (findIdea ideaId) <*> pure Nothing)
        (currentUserAddDb $ AddCommentToIdea loc ideaId)

replyCommentIdea :: ActionM m => IdeaLocation -> AUID Idea -> AUID Comment -> FormPageHandler m CommentIdea
replyCommentIdea loc ideaId commentId =
    FormPageHandler
        (mquery $ do
            midea <- findIdea ideaId
            pure $ do idea <- midea
                      comment <- idea ^. ideaComments . at commentId
                      pure $ CommentIdea idea (Just comment))
        (currentUserAddDb . AddReply $ CommentKey loc ideaId [] commentId)

judgeIdea :: ActionM m => AUID Idea -> IdeaJuryResultType -> FormPageHandler m JudgeIdea
judgeIdea ideaId juryType =
    FormPageHandler
        (equery $ do
            idea  <- maybe404 =<< findIdea ideaId
            topic <- maybe404 =<< ideaTopic idea
            pure $ JudgeIdea juryType idea topic)
        (Action.markIdeaInJuryPhase ideaId)

creatorStatementOfIdea :: Idea -> Maybe Document
creatorStatementOfIdea idea = idea ^? ideaVoteResult . _Just . ideaVoteResultValue . _Winning . _Just

creatorStatement :: ActionM m => AUID Idea -> FormPageHandler m CreatorStatement
creatorStatement ideaId =
    FormPageHandler
        (CreatorStatement <$> mquery (findIdea ideaId))
        (Action.setCreatorStatement ideaId)
