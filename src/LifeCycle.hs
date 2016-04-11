{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module LifeCycle
where

import Control.Lens

import Types hiding (Comment)


-- * Phase transition matrix

data PhaseChange
    = RefinementPhaseTimeOut
    | RefinementPhaseMarkedByModerator
    | AllIdeasAreMarked Timestamp
    | VotingPhaseTimeOut
  deriving (Eq, Show)

data PhaseAction
    = JuryPhasePrincipalEmail
    | ResultPhaseModeratorEmail
    -- FIXME: Add more action here.
  deriving (Eq, Show)


phaseTrans :: Phase -> PhaseChange -> Maybe (Phase, [PhaseAction])
phaseTrans (PhaseRefinement _) RefinementPhaseTimeOut
    = Just (PhaseJury, [JuryPhasePrincipalEmail])
phaseTrans (PhaseRefinement _) RefinementPhaseMarkedByModerator
    = Just (PhaseJury, [JuryPhasePrincipalEmail])
phaseTrans PhaseJury (AllIdeasAreMarked newPhaseDuration)
    = Just (PhaseVoting newPhaseDuration, [])
phaseTrans (PhaseVoting _) VotingPhaseTimeOut
    = Just (PhaseResult, [ResultPhaseModeratorEmail])
phaseTrans _ _ = Nothing


-- * Idea Capabilities

-- | What a user can do with an idea.
--
-- The view of an idea is default and controlled
-- by access control.
-- FIXME: More possible actions what can a user do with an idea.
data IdeaCapability
    = QuorumVote -- aka Like
    | Vote
    | Comment
    | MarkFeasiblity -- also can add jury statement
    | MarkWinner
    | AddCreatorStatement
--    | Edit
  deriving (Enum, Eq, Ord, Show)

ideaCapabilities :: AUID User -> Idea -> Maybe Phase -> Role -> [IdeaCapability]
ideaCapabilities _ i Nothing  r = wildIdeaCap i r
ideaCapabilities u i (Just p) r = case p of
    PhaseRefinement _ -> phaseRefinementCap i r
    PhaseJury         -> phaseJuryCap i r
    PhaseVoting     _ -> phaseVotingCap i r
    PhaseResult       -> phaseResultCap u i r

wildIdeaCap :: Idea -> Role -> [IdeaCapability]
wildIdeaCap _i = \case
    Student    _clss -> [QuorumVote, Comment]
    ClassGuest _clss -> []
    SchoolGuest      -> []
    Moderator        -> []
    Principal        -> []
    Admin            -> []

phaseRefinementCap :: Idea -> Role -> [IdeaCapability]
phaseRefinementCap _i = \case
    Student    _clss -> [Comment]
    ClassGuest _clss -> []
    SchoolGuest      -> []
    Moderator        -> []
    Principal        -> []
    Admin            -> []

phaseJuryCap :: Idea -> Role -> [IdeaCapability]
phaseJuryCap _i = \case
    Student    _clss -> []
    ClassGuest _clss -> []
    SchoolGuest      -> []
    Moderator        -> []
    Principal        -> [MarkFeasiblity]
    Admin            -> []

phaseVotingCap :: Idea -> Role -> [IdeaCapability]
phaseVotingCap i = \case
    Student    _clss -> onFeasibleIdea i [Vote]
    ClassGuest _clss -> []
    SchoolGuest      -> []
    Moderator        -> []
    Principal        -> []
    Admin            -> []

phaseResultCap :: AUID User -> Idea -> Role -> [IdeaCapability]
phaseResultCap u i = \case
    Student    _clss -> [AddCreatorStatement | u `isCreatorOf` i]
    ClassGuest _clss -> []
    SchoolGuest      -> []
    Moderator        -> onFeasibleIdea i [MarkWinner]
    Principal        -> []
    Admin            -> []


-- ** Helpers

onFeasibleIdea :: Idea -> [IdeaCapability] -> [IdeaCapability]
onFeasibleIdea i cs = if isFeasibleIdea i then cs else []

-- | An alternative implementation with lenses instead of view patterns:
--
-- >>> isFeasibleIdea :: Idea -> Bool
-- >>> isFeasibleIdea idea = case idea ^? ideaResult . _Just . ideaResultValue of
-- >>>     Just (Feasible _) -> True
-- >>>     _ -> False
isFeasibleIdea :: Idea -> Bool
isFeasibleIdea (view ideaJuryResult -> (Just (view ideaJuryResultValue -> Feasible _)))
    = True
isFeasibleIdea _
    = False

isCreatorOf :: HasMetaInfo a => AUID User -> a -> Bool
isCreatorOf u = (u ==) . view createdBy
