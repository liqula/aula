{-# LANGUAGE ConstraintKinds             #-}
{-# LANGUAGE DataKinds                   #-}
{-# LANGUAGE DefaultSignatures           #-}
{-# LANGUAGE DeriveGeneric               #-}
{-# LANGUAGE FlexibleContexts            #-}
{-# LANGUAGE FlexibleInstances           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE KindSignatures              #-}
{-# LANGUAGE LambdaCase                  #-}
{-# LANGUAGE MultiParamTypeClasses       #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE Rank2Types                  #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TemplateHaskell             #-}
{-# LANGUAGE TypeFamilies                #-}
{-# LANGUAGE TypeOperators               #-}
{-# LANGUAGE TypeSynonymInstances        #-}
{-# LANGUAGE ViewPatterns                #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Types.Core
where

import Control.Lens hiding ((<.>))
import Control.Monad
import Data.Char
import Data.Function (on)
import Data.List as List (zipWith)
import Data.Set as Set (Set)
import Data.Map as Map (Map, lookup, unions, singleton)
import Data.Proxy (Proxy(Proxy))
import Data.SafeCopy (base, SafeCopy(..), safeGet, safePut, contain, deriveSafeCopy)
import Data.String
import Data.String.Conversions
import Data.UriPath (HasUriPart(uriPart))
import GHC.Generics (Generic)
import Network.HTTP.Media ((//))
import Servant.API
    ( FromHttpApiData(parseUrlPiece), ToHttpApiData(toUrlPiece)
    , Accept, MimeRender, Headers(..), Header, contentType, mimeRender, addHeader
    )
import System.FilePath ((</>), (<.>))
import Text.Read (readMaybe)

import qualified Data.Aeson as Aeson
import qualified Data.Csv as CSV
import qualified Data.Text as ST
import qualified Data.Vector as Vector
import qualified Generics.Generic.Aeson as Aeson
import qualified Generics.SOP as SOP
import qualified Text.Email.Validate as Email

import Types.Prelude
import Data.Markdown
import Frontend.Constant


-- * prototypes for types

-- | Prototype for a type.
-- The prototypes contains all the information which cannot be
-- filled out of some type. Information which comes from outer
-- source and will be saved into the database.
--
-- FIXME: move this into 'FromProto'?
type family Proto type_ :: *

-- | The method how a 't' value is calculated from its prototype
-- and a metainfo to that.
class FromProto t where
    fromProto :: Proto t -> MetaInfo t -> t


-- * metainfo

-- | General information on objects stored in the DB.
--
-- Some of these fields, like login name and avatar url of creator, are redundant.  The reason to
-- keep them here is that it makes it easy to keep large 'Page*' types containing many nested
-- objects, and still allowing all these objects to be rendered purely only based on the information
-- they contain.
--
-- If this is becoming too much in the future and we want to keep objects around without all this
-- inlined information, we should consider making objects polymorphic in the concrete meta info
-- type.  Example: 'Idea MetaInfo', but also 'Idea ShortMetaInfo'.
-- np@2016-04-18: Actually `Idea MetaInfo` does not work well. Parameters of kind `* -> *` are not
-- well supported by generics and deriving mechanisms.
data GMetaInfo a k = MetaInfo
    { _metaKey             :: k
    , _metaCreatedBy       :: AUID User
    , _metaCreatedByLogin  :: UserLogin
    , _metaCreatedAt       :: Timestamp
    , _metaChangedBy       :: AUID User
    , _metaChangedAt       :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic)

type MetaInfo a = GMetaInfo a (KeyOf a)


-- * database keys

-- | Aula Unique ID for reference in the database.  This is unique for one concrete phantom type
-- only and will probably be generated by sql `serial` type.
newtype AUID a = AUID { _unAUID :: Integer }
  deriving (Eq, Ord, Show, Read, Generic, FromHttpApiData, Enum, Real, Num, Integral)

type family   KeyOf a
type instance KeyOf User             = AUID User
type instance KeyOf Idea             = AUID Idea
type instance KeyOf IdeaVote         = IdeaVoteLikeKey
type instance KeyOf IdeaLike         = IdeaVoteLikeKey
type instance KeyOf IdeaVoteResult   = AUID IdeaVoteResult
type instance KeyOf IdeaJuryResult   = AUID IdeaJuryResult
type instance KeyOf Topic            = AUID Topic
type instance KeyOf Delegation       = AUID Delegation
type instance KeyOf Comment          = CommentKey
type instance KeyOf CommentVote      = CommentVoteKey

-- | Extracts the identifier (AUID) from a key (KeyOf).
-- The identifier corresponds to the key of the last map (AMap).
--
-- For some types such as User, the key and the identifier are identical.
--
-- For a comment vote, the key is a composite of the comment key and the user id.
-- The identifier of a comment vote is only the user id part of the key.
--
-- So far all identifiers are of type AUID we shall try to keep it that way.
type family   IdOfKey a
type instance IdOfKey (AUID a)        = AUID a
type instance IdOfKey CommentKey      = AUID Comment
type instance IdOfKey CommentVoteKey  = AUID User
type instance IdOfKey IdeaVoteLikeKey = AUID User

type IdOf a = IdOfKey (KeyOf a)


-- * database maps

type AMap a = Map (IdOf a) a

type Users        = AMap User
type Ideas        = AMap Idea
type Topics       = AMap Topic
type Comments     = AMap Comment
type CommentVotes = AMap CommentVote
type IdeaVotes    = AMap IdeaVote
type IdeaLikes    = AMap IdeaLike


-- * user

data User = User
    { _userMeta      :: MetaInfo User
    , _userLogin     :: UserLogin
    , _userFirstName :: UserFirstName
    , _userLastName  :: UserLastName
    , _userRoleSet   :: Set Role
    , _userDesc      :: Document
    , _userSettings  :: UserSettings
    }
  deriving (Eq, Ord, Show, Read, Generic)

newtype UserLogin     = UserLogin     { _unUserLogin     :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

newtype UserFirstName = UserFirstName { _unUserFirstName :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

newtype UserLastName  = UserLastName  { _unUserLastName  :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

data UserSettings = UserSettings
    { _userSettingsPassword :: UserPass
    , _userSettingsEmail    :: Maybe EmailAddress
    }
  deriving (Eq, Ord, Show, Read, Generic)

newtype EmailAddress = InternalEmailAddress { internalEmailAddress :: Email.EmailAddress }
    deriving (Eq, Ord, Show, Read, Generic)

data UserPass =
    UserPassInitial   { _userPassInitial   :: InitialPassword }
  | UserPassEncrypted { _userPassEncrypted :: EncryptedPassword }
  | UserPassDeactivated
  deriving (Eq, Ord, Show, Read, Generic)

newtype InitialPassword = InitialPassword { _unInitialPassword :: ST }
  deriving (Eq, Ord, Show, Read, Generic)

newtype EncryptedPassword = ScryptEncryptedPassword { _unScryptEncryptedPassword :: SBS }
  deriving (Eq, Ord, Show, Read, Generic)


-- | Users are never deleted, just marked as deleted.
data UserView
    = ActiveUser  { _activeUser  :: User }
    | DeletedUser { _deletedUser :: User }
  deriving (Eq, Ord, Show, Read, Generic)

data ProtoUser = ProtoUser
    { _protoUserLogin     :: Maybe UserLogin
    , _protoUserFirstName :: UserFirstName
    , _protoUserLastName  :: UserLastName
    , _protoUserRoleSet   :: Set Role
    , _protoUserPassword  :: InitialPassword
    , _protoUserEmail     :: Maybe EmailAddress
    , _protoUserDesc      :: Document
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto User = ProtoUser


-- * role

-- | Note that all roles except 'Student' and 'ClassGuest' have the same access to all IdeaSpaces.
-- (Rationale: e.g. teachers have trust each other and can cover for each other.)
data Role =
    Student    { _roleSchoolClass :: SchoolClass }
  | ClassGuest { _roleSchoolClass :: SchoolClass } -- ^ e.g., parents
  | SchoolGuest  -- ^ e.g., researchers
  | Moderator
  | Principal
  | Admin
  deriving (Eq, Ord, Show, Read, Generic)

parseRole :: (IsString err, Monoid err) => [ST] -> Either err Role
parseRole = \case
    ["admin"]      -> pure Admin
    ["principal"]  -> pure Principal
    ["moderator"]  -> pure Moderator
    ("student":xs) -> Student <$> parseSchoolClassCode xs
    ("guest":xs)   -> guestRole <$> parseIdeaSpaceCode xs
    _              -> Left "Ill-formed role"

parseIdeaSpaceCode :: (IsString err, Monoid err) => [ST] -> Either err IdeaSpace
parseIdeaSpaceCode = \case
    ["school"] -> pure SchoolSpace
    xs         -> ClassSpace <$> parseSchoolClassCode xs

parseSchoolClassCode :: (IsString err, Monoid err) => [ST] -> Either err SchoolClass
parseSchoolClassCode = \case
    [year, name] -> (`SchoolClass` name) <$> readYear year
    _:_:_:_      -> err "Too many parts (two parts expected)"
    _            -> err "Too few parts (two parts expected)"
  where
    err msg = Left $ "Ill-formed school class: " <> msg
    readYear = maybe (err "Year should be only digits") Right . readMaybe . cs

guestRole :: IdeaSpace -> Role
guestRole = \case
    SchoolSpace  -> SchoolGuest
    ClassSpace c -> ClassGuest c


-- * idea

-- | "Idee".  Ideas can be either be wild or contained in exactly one 'Topic'.
data Idea = Idea
    { _ideaMeta       :: MetaInfo Idea
    , _ideaTitle      :: ST
    , _ideaDesc       :: Document
    , _ideaCategory   :: Maybe Category
    , _ideaLocation   :: IdeaLocation
    , _ideaComments   :: Comments
    , _ideaLikes      :: IdeaLikes
    , _ideaVotes      :: IdeaVotes
    , _ideaJuryResult :: Maybe IdeaJuryResult  -- invariant: isJust => phase of containing topic > JuryPhsae
    , _ideaVoteResult :: Maybe IdeaVoteResult  -- invariant: isJust => phase of containing topic > VotingPhase
    , _ideaDeleted    :: Bool
    }
  deriving (Eq, Ord, Show, Read, Generic)

-- | Invariant: for all @IdeaLocationTopic space tid@: idea space of topic with id 'tid' is 'space'.
data IdeaLocation =
      IdeaLocationSpace { _ideaLocationSpace :: IdeaSpace }
    | IdeaLocationTopic { _ideaLocationSpace :: IdeaSpace, _ideaLocationTopicId :: AUID Topic }
  deriving (Eq, Ord, Show, Read, Generic)

-- | Prototype for Idea creation.
data ProtoIdea = ProtoIdea
    { _protoIdeaTitle      :: ST
    , _protoIdeaDesc       :: Document
    , _protoIdeaCategory   :: Maybe Category
    , _protoIdeaLocation   :: IdeaLocation
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto Idea = ProtoIdea

-- | "Kategorie"
data Category =
    CatRules        -- ^ "Regel"
  | CatEquipment    -- ^ "Ausstattung"
  | CatTeaching     -- ^ "Unterricht"
  | CatTime         -- ^ "Zeit"
  | CatEnvironment  -- ^ "Umgebung"
  deriving (Eq, Ord, Bounded, Enum, Show, Read, Generic)

-- | endorsement, or interest.
data IdeaLike = IdeaLike
    { _ideaLikeMeta     :: MetaInfo IdeaLike
    , _ideaLikeDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

data ProtoIdeaLike = ProtoIdeaLike
    { _protoIdeaLikeDelegate :: AUID User
    }

type instance Proto IdeaLike = ProtoIdeaLike

-- | "Stimme" for "Idee".  As opposed to 'CommentVote'.
data IdeaVote = IdeaVote
    { _ideaVoteMeta     :: MetaInfo IdeaVote
    , _ideaVoteValue    :: IdeaVoteValue
    , _ideaVoteDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

data ProtoIdeaVote = ProtoIdeaVote
    { _protoIdeaVoteValue    :: IdeaVoteValue
    , _protoIdeaVoteDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto IdeaVote = ProtoIdeaVote

data IdeaVoteValue = Yes | No
  deriving (Eq, Ord, Enum, Bounded, Show, Read, Generic)

data IdeaVoteLikeKey = IdeaVoteLikeKey
    { _ivIdea :: AUID Idea
    , _ivUser :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

data IdeaJuryResult = IdeaJuryResult
    { _ideaJuryResultMeta   :: MetaInfo IdeaJuryResult
    , _ideaJuryResultValue  :: IdeaJuryResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic)

data IdeaJuryResultType
    = IdeaNotFeasible
    | IdeaFeasible
  deriving (Eq, Ord, Show, Read, Generic)

data IdeaJuryResultValue
    = NotFeasible { _ideaResultNotFeasibleReason :: Document }
    | Feasible    { _ideaResultFeasibleReason    :: Maybe Document }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto IdeaJuryResult = IdeaJuryResultValue

ideaResultReason :: Traversal' IdeaJuryResultValue Document
ideaResultReason f = \case
    NotFeasible d -> NotFeasible <$> f d
    Feasible md   -> Feasible <$> traverse f md

data IdeaVoteResult = IdeaVoteResult
    { _ideaVoteResultMeta   :: MetaInfo IdeaVoteResult
    , _ideaVoteResultValue  :: IdeaVoteResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic)

data IdeaVoteResultValue
    = Winning { _ideaResultCreatorStatement :: Maybe Document }
    | EnoughVotes Bool
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto IdeaVoteResult = IdeaVoteResultValue


-- * comment

-- | "Verbesserungsvorschlag"
--
-- 'Comments' are hierarchical.  The application logic is responsible for putting some limit (if
-- any) on the recursion depth under which all children become siblings.
--
-- A comment has no implicit 'yes' vote by the author.  This gives the author the option of voting
-- for a comment, or even against it.  Even though the latter may never make sense, somebody may
-- still learn something from trying it out, and this is a teaching application.
data Comment = Comment
    { _commentMeta    :: MetaInfo Comment
    , _commentText    :: Document
    , _commentVotes   :: CommentVotes
    , _commentReplies :: Comments
    , _commentDeleted :: Bool
    }
  deriving (Eq, Ord, Show, Read, Generic)


-- | This is the complete information to recover a comment in AulaData
-- * ckParents: Comment identifiers from the root to the leaf. If `y`, follows `x` in ckParents,
--              then `y` is a reply to `x`. See also `traverseParents` for a use of that field.
data CommentKey = CommentKey
    { _ckIdeaLocation  :: IdeaLocation
    , _ckIdeaId        :: AUID Idea
    , _ckParents       :: [AUID Comment]
    , _ckCommentId     :: AUID Comment
    }
  deriving (Eq, Ord, Show, Read, Generic)

commentKey :: IdeaLocation -> AUID Idea -> AUID Comment -> CommentKey
commentKey loc iid = CommentKey loc iid []

replyKey :: IdeaLocation -> AUID Idea -> AUID Comment -> AUID Comment -> CommentKey
replyKey loc iid pid = CommentKey loc iid [pid]

data CommentVoteKey = CommentVoteKey
    { _cvCommentKey :: CommentKey
    , _cvUser      :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

newtype CommentContent = CommentContent { unCommentContent :: Document }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto Comment = CommentContent

-- | "Stimme" for "Verbesserungsvorschlag"
data CommentVote = CommentVote
    { _commentVoteMeta  :: MetaInfo CommentVote
    , _commentVoteValue :: UpDown
    }
  deriving (Eq, Ord, Show, Read, Generic)

data UpDown = Up | Down
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

type instance Proto CommentVote = UpDown

data CommentContext = CommentContext
    { _parentIdea    :: Idea
    , _parentComment :: Maybe Comment
    }
  deriving (Eq, Ord, Show, Read, Generic)


-- * idea space, topic, phase

-- | "Ideenraum" is one of "Klasse", "Schule".
data IdeaSpace =
    SchoolSpace
  | ClassSpace { _ideaSpaceSchoolClass :: SchoolClass }
  deriving (Eq, Show, Read, Generic)

-- | "Klasse".  (The school year is necessary as the class name is used for a fresh set of students
-- every school year.)
data SchoolClass = SchoolClass
    { _classSchoolYear :: Int -- ^ e.g. 2015
    , _className       :: ST  -- ^ e.g. "7a"
    }
  deriving (Eq, Ord, Show, Read, Generic)

-- | FIXME: SchoolClass shouldn't have an empty text, ever.  We avoid the distinction in some other
-- way, like with making 'Role' a parametric type.  (anyway, could we make this a pattern synonym?)
nilSchoolClass :: SchoolClass -> Bool
nilSchoolClass (SchoolClass _ "") = True
nilSchoolClass _                  = False

-- | FIXME: needs to be gone by the end of school year 2016!
theOnlySchoolYearHack :: Int
theOnlySchoolYearHack = 2016


ideaSpaceCode :: IdeaSpace -> String
ideaSpaceCode SchoolSpace    = "school"
ideaSpaceCode (ClassSpace c) = schoolClassCode c

schoolClassCode :: SchoolClass -> String
schoolClassCode c = show (_classSchoolYear c) <> "-" <> cs (_className c)


-- | A 'Topic' is created inside an 'IdeaSpace'.  It is used as a container for a "wild idea" that
-- has reached a quorum, plus more ideas that the moderator decides belong here.  'Topic's have
-- 'Phase's.  All 'Idea's in a 'Topic' must have the same 'IdeaSpace' as the 'Topic'.
data Topic = Topic
    { _topicMeta      :: MetaInfo Topic
    , _topicTitle     :: ST
    , _topicDesc      :: PlainDocument
    , _topicImage     :: URL
    , _topicIdeaSpace :: IdeaSpace
    , _topicPhase     :: Phase
    }
  deriving (Eq, Ord, Show, Read, Generic)

data ProtoTopic = ProtoTopic
    { _protoTopicTitle       :: ST
    , _protoTopicDesc        :: PlainDocument
    , _protoTopicImage       :: URL
    , _protoTopicIdeaSpace   :: IdeaSpace
    , _protoTopicIdeas       :: [AUID Idea]
    , _protoTopicRefPhaseEnd :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto Topic = ProtoTopic


-- * topic phases

data PhaseStatus
  = ActivePhase { _phaseEnd :: Timestamp }
  | FrozenPhase { _phaseLeftover :: Timespan }
  deriving (Eq, Ord, Show, Read, Generic)

-- | Topic phases.  (Phase 1.: "wild ideas", is where 'Topic's are born, and we don't need a
-- constructor for that here.)
data Phase =
    PhaseWildIdea   { _phaseWildFrozen :: Freeze }
  | PhaseRefinement { _phaseStatus :: PhaseStatus }
                               -- ^ 2. "Ausarbeitungsphase"
  | PhaseJury                  -- ^ 3. "Prüfungsphase"
  | PhaseVoting     { _phaseStatus :: PhaseStatus }
                               -- ^ 4. "Abstimmungsphase"
  | PhaseResult                -- ^ 5. "Ergebnisphase"
  deriving (Eq, Ord, Show, Read, Generic)

data Freeze = NotFrozen | Frozen
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)


-- * delegations

data DelegationNetwork = DelegationNetwork
    { _networkUsers         :: [(User, Int)]  -- ^ 'User's and their 'votingPower's.
    , _networkDelegations   :: [Delegation]
    }
  deriving (Eq, Show, Read, Generic)

-- | "Beauftragung"
data Delegation = Delegation
    { _delegationScope :: DScope
    , _delegationFrom  :: AUID User
    , _delegationTo    :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto Delegation = Delegation

-- | Node type for the delegation scope hierarchy DAG.  The four levels are 'Idea', 'Topic',
-- 'SchoolClass', and global.
--
-- There 'SchoolClass' level could reference an 'IdeaSpace' instead, but there is a subtle
-- difference between delegation in school space and globally that we would like to avoid having to
-- explain to our users, so we do not allow delegation in school space, and collapse 'school' and
-- 'global' liberally in the UI.  We enforce this collapse in this type.
--
-- Example to demonstrate the difference: If idea @A@ lives in class @C@, and user @X@ votes yes on
-- @A@, consider the two cases: If I delegate to user @X@ on school space level, @A@ is not covered,
-- because it lives in a different space, so user @X@ does *not* cast my vote.  If I delegate to
-- user @X@ *globally*, @A@ *is* covered, and @X@ *does* cast my vote.
--
-- The reason for this confusion is related to idea space membership, which is different for school:
-- every user is implicitly a member of the idea space "school", whereas membership in all other
-- idea spaces is explicit in the role.  However, this does not necessarily (although
-- coincidentally) constitute a subset relationship between class spaces and school space.
data DScope =
    DScopeGlobal
  | DScopeIdeaSpace { _dScopeIdeaSpace :: IdeaSpace  }
  | DScopeTopicId   { _dScopeTopicId   :: AUID Topic }
  | DScopeIdeaId    { _dScopeIdeaId    :: AUID Idea  }
  deriving (Eq, Ord, Show, Read, Generic)

-- | 'DScope', but with the references resolved.  (We could do a more general type @DScope a@ and
-- introduce two synonyms for @DScope AUID@ and @DScope Identity@, but it won't make things any
-- easier.)
data DScopeFull =
    DScopeGlobalFull
  | DScopeIdeaSpaceFull { _dScopeIdeaSpaceFull :: IdeaSpace }
  | DScopeTopicFull     { _dScopeTopicFull     :: Topic     }
  | DScopeIdeaFull      { _dScopeIdeaFull      :: Idea      }
  deriving (Eq, Ord, Show, Read, Generic)


-- * avatar locators

type AvatarDimension = Int

avatarFile :: Maybe AvatarDimension -> Getter (AUID a) FilePath
avatarFile mdim = to $ \uid -> "static" </> "avatars" </> cs (uriPart uid) <> sdim <.> "png"
  where
    sdim = mdim ^. _Just . showed . to ("-" <>)

-- | See "Frontend.Constant.avatarDefaultSize"
avatarUrl :: AvatarDimension -> Getter (AUID a) URL
avatarUrl dim = to $ \uid -> "/" <> uid ^. avatarFile mdim . csi
  where
    mdim | dim == avatarDefaultSize = Nothing
         | otherwise                = Just dim

userAvatar :: AvatarDimension -> Getter User URL
userAvatar dim = to _userMeta . to _metaKey . avatarUrl dim


-- * csv helpers

data CSV

instance Accept CSV where
    contentType Proxy = "text" // "csv"

type CsvHeaders a = Headers '[CsvHeadersContentDisposition] a
type CsvHeadersContentDisposition = Header "Content-Disposition" String  -- appease hlint v1.9.22

instance MimeRender CSV a => MimeRender CSV (CsvHeaders a) where
    mimeRender proxy (Headers v _) = mimeRender proxy v

csvHeaders :: String -> a -> CsvHeaders a
csvHeaders filename = addHeader $ "attachment; filename=" <> filename <> ".csv"


-- * misc

newtype DurationDays = DurationDays { unDurationDays :: Int }
  deriving (Eq, Ord, Show, Read, Num, Enum, Real, Integral, Generic)


-- | Percentage values from 0 to 100, used in quorum computations.
type Percent = Int


-- | Transform values into strings suitable for presenting to the user.  These strings are not
-- machine-readable in general.  (alternative names that lost in a long bikeshedding session:
-- @HasUIString@, @HasUIText@, ...)
class HasUILabel a where
    uilabel :: a -> (Monoid s, IsString s) => s

    uilabelST :: a -> ST
    uilabelST = uilabel

    uilabeled :: (Monoid s, IsString s) => Getter a s
    uilabeled = to uilabel

    uilabeledST :: Getter a ST
    uilabeledST = to uilabel


-- * instances

instance HasUriPart (AUID a) where
    uriPart (AUID s) = fromString . show $ s


-- ** user, role

instance CSV.FromField EmailAddress where
    parseField f = either fail (pure . InternalEmailAddress) . Email.validate =<< CSV.parseField f

instance SafeCopy EmailAddress where
    kind = base
    getCopy = contain $ maybe mzero (pure . InternalEmailAddress) . Email.emailAddress =<< safeGet
    putCopy = contain . safePut . Email.toByteString . internalEmailAddress

instance FromHttpApiData Role where
    parseUrlPiece = parseRole . ST.splitOn "-"

instance HasUILabel Role where
    uilabel = \case
        (Student c)
          | nilSchoolClass c -> "Schüler"
          | otherwise        -> "Schüler (" <> uilabel c <> ")"
        (ClassGuest c)
          | nilSchoolClass c -> "Gast"
          | otherwise        -> "Gast (" <> uilabel c <> ")"
        SchoolGuest    -> "Gast (Schule)"
        Moderator      -> "Moderator"
        Principal      -> "Direktor"
        Admin          -> "Administrator"

instance HasUriPart Role where
    uriPart = \case
        (Student c)    -> "student-" <> uriPart c
        (ClassGuest c) -> "guest-" <> uriPart c
        SchoolGuest    -> "guest-school"
        Moderator      -> "moderator"
        Principal      -> "principal"
        Admin          -> "admin"


-- ** idea

instance HasUILabel Category where
    uilabel = \case
        CatRules       -> "Regeln"
        CatEquipment   -> "Ausstattung"
        CatTeaching    -> "Unterricht"
        CatTime        -> "Zeit"
        CatEnvironment -> "Umgebung"

instance ToHttpApiData Category where
    toUrlPiece = \case
        CatRules       -> "rules"
        CatEquipment   -> "equipment"
        CatTeaching    -> "teaching"
        CatTime        -> "time"
        CatEnvironment -> "environment"

instance FromHttpApiData Category where
    parseUrlPiece = \case
        "rules"       -> Right CatRules
        "equipment"   -> Right CatEquipment
        "teaching"    -> Right CatTeaching
        "time"        -> Right CatTime
        "environment" -> Right CatEnvironment
        _             -> Left "no parse"


instance HasUriPart IdeaJuryResultType where
    uriPart = fromString . cs . toUrlPiece

instance ToHttpApiData IdeaJuryResultType where
    toUrlPiece = \case
      IdeaNotFeasible -> "good"
      IdeaFeasible    -> "bad"

instance FromHttpApiData IdeaJuryResultType where
    parseUrlPiece = \case
      "good" -> Right IdeaNotFeasible
      "bad"  -> Right IdeaFeasible
      _      -> Left "Ill-formed idea vote value: only `good' or `bad' are allowed"


instance HasUriPart IdeaVoteValue where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData IdeaVoteValue where
    parseUrlPiece = \case
        "yes"     -> Right Yes
        "no"      -> Right No
        _         -> Left "Ill-formed idea vote value: only `yes' or `no' are allowed"

instance HasUriPart UpDown where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData UpDown where
    parseUrlPiece = \case
        "up"   -> Right Up
        "down" -> Right Down
        _      -> Left "Ill-formed comment vote value: only `up' or `down' are expected)"


-- * location, space, topic

instance HasUILabel IdeaLocation where
    uilabel (IdeaLocationSpace s) = uilabel s
    uilabel (IdeaLocationTopic s (AUID t)) = "Thema #" <> fromString (show t) <> " in " <> uilabel s


-- e.g.: ["Klasse 10a", "Klasse 7b", "Klasse 7a"]
--   ==> ["Klasse 7a", "Klasse 7b", "Klasse 10a"]
instance Ord IdeaSpace where
    compare = compare `on` sortableName
      where
        sortableName :: IdeaSpace -> Maybe [Either String Int]
        sortableName SchoolSpace     = Nothing
        sortableName (ClassSpace cl) = Just . structured . cs . _className $ cl

        structured :: String -> [Either String Int]
        structured = nonDigits
          where
            digits xs = case span isDigit xs of
                            ([], []) -> []
                            ([], zs) -> nonDigits zs
                            (ys, zs) -> Right (read ys) : nonDigits zs
            nonDigits xs = case break isDigit xs of
                            ([], []) -> []
                            ([], zs) -> digits zs
                            (ys, zs) -> Left ys : digits zs

instance HasUILabel IdeaSpace where
    uilabel = \case
        SchoolSpace    -> "Schule"
        (ClassSpace c) -> "Klasse " <> uilabel c

instance HasUriPart IdeaSpace where
    uriPart = fromString . ideaSpaceCode

instance ToHttpApiData IdeaSpace where
    toUrlPiece = cs . ideaSpaceCode

instance FromHttpApiData IdeaSpace where
    parseUrlPiece = parseIdeaSpaceCode . ST.splitOn "-"


-- | for the first school year, we can ignore the year.  (after that, we have different options.
-- one would be to only show the year if it is not the current one, or always show it, or either
-- show "current" if applicable or the actual year if it lies in the past.)
instance HasUILabel SchoolClass where
    uilabel = fromString . cs . _className

instance HasUriPart SchoolClass where
    uriPart = fromString . schoolClassCode

instance FromHttpApiData SchoolClass where
    parseUrlPiece = parseSchoolClassCode . ST.splitOn "-"


-- ** delegations

instance HasUILabel Phase where
    uilabel = \case
        PhaseWildIdea{}   -> "Wilde-Ideen-Phase"  -- FIXME: unreachable as of the writing of this
                                                  -- comment, but used for some tests
        PhaseRefinement{} -> "Ausarbeitungsphase"
        PhaseJury         -> "Prüfungsphase"
        PhaseVoting{}     -> "Abstimmungsphase"
        PhaseResult       -> "Ergebnisphase"

instance ToHttpApiData DScope where
    toUrlPiece = (cs :: String -> ST). \case
        DScopeGlobal -> "global"
        (DScopeIdeaSpace space) -> "ideaspace-" <> cs (toUrlPiece space)
        (DScopeTopicId (AUID topicId)) -> "topic-" <> show topicId
        (DScopeIdeaId (AUID ideaId)) -> "idea-" <> show ideaId

instance FromHttpApiData DScope where
    parseUrlPiece scope = case cs scope of
        "global" -> Right DScopeGlobal
        'i':'d':'e':'a':'s':'p':'a':'c':'e':'-':space -> DScopeIdeaSpace <$> parseUrlPiece (cs space)
        't':'o':'p':'i':'c':'-':topicId -> DScopeTopicId . AUID <$> readEitherCS topicId
        'i':'d':'e':'a':'-':ideaId -> DScopeIdeaId . AUID <$> readEitherCS ideaId
        _ -> Left "no parse"

instance HasUILabel DScopeFull where
    uilabel = \case
        DScopeGlobalFull       -> "Schule"
        DScopeIdeaSpaceFull is -> "Ideenraum " <> (fromString . cs . uilabelST   $ is)
        DScopeTopicFull t      -> "Thema "     <> (fromString . cs . _topicTitle $ t)
        DScopeIdeaFull i       -> "Idee "      <> (fromString . cs . _ideaTitle  $ i)


-- ** SOP

instance SOP.Generic (AUID a)
instance SOP.Generic Category
instance SOP.Generic Comment
instance SOP.Generic CommentContent
instance SOP.Generic CommentContext
instance SOP.Generic CommentKey
instance SOP.Generic CommentVote
instance SOP.Generic CommentVoteKey
instance SOP.Generic Delegation
instance SOP.Generic DelegationNetwork
instance SOP.Generic DScope
instance SOP.Generic DScopeFull
instance SOP.Generic DurationDays
instance SOP.Generic EncryptedPassword
instance SOP.Generic Freeze
instance SOP.Generic id => SOP.Generic (GMetaInfo a id)
instance SOP.Generic Idea
instance SOP.Generic IdeaJuryResult
instance SOP.Generic IdeaJuryResultType
instance SOP.Generic IdeaJuryResultValue
instance SOP.Generic IdeaLike
instance SOP.Generic IdeaLocation
instance SOP.Generic IdeaSpace
instance SOP.Generic IdeaVote
instance SOP.Generic IdeaVoteLikeKey
instance SOP.Generic IdeaVoteResult
instance SOP.Generic IdeaVoteResultValue
instance SOP.Generic IdeaVoteValue
instance SOP.Generic InitialPassword
instance SOP.Generic Phase
instance SOP.Generic PhaseStatus
instance SOP.Generic ProtoIdea
instance SOP.Generic ProtoIdeaVote
instance SOP.Generic ProtoTopic
instance SOP.Generic ProtoUser
instance SOP.Generic Role
instance SOP.Generic Topic
instance SOP.Generic UpDown
instance SOP.Generic User
instance SOP.Generic UserPass
instance SOP.Generic UserSettings


-- * safe copy

deriveSafeCopy 0 'base ''AUID
deriveSafeCopy 0 'base ''Category
deriveSafeCopy 0 'base ''Comment
deriveSafeCopy 0 'base ''CommentContent
deriveSafeCopy 0 'base ''CommentKey
deriveSafeCopy 0 'base ''CommentVote
deriveSafeCopy 0 'base ''CommentVoteKey
deriveSafeCopy 0 'base ''Delegation
deriveSafeCopy 0 'base ''DelegationNetwork
deriveSafeCopy 0 'base ''DScope
deriveSafeCopy 0 'base ''DurationDays
deriveSafeCopy 0 'base ''EncryptedPassword
deriveSafeCopy 0 'base ''Freeze
deriveSafeCopy 0 'base ''GMetaInfo
deriveSafeCopy 0 'base ''Idea
deriveSafeCopy 0 'base ''IdeaJuryResult
deriveSafeCopy 0 'base ''IdeaJuryResultValue
deriveSafeCopy 0 'base ''IdeaLike
deriveSafeCopy 0 'base ''IdeaLocation
deriveSafeCopy 0 'base ''IdeaSpace
deriveSafeCopy 0 'base ''IdeaVote
deriveSafeCopy 0 'base ''IdeaVoteLikeKey
deriveSafeCopy 0 'base ''IdeaVoteResult
deriveSafeCopy 0 'base ''IdeaVoteResultValue
deriveSafeCopy 0 'base ''IdeaVoteValue
deriveSafeCopy 0 'base ''InitialPassword
deriveSafeCopy 0 'base ''Phase
deriveSafeCopy 0 'base ''PhaseStatus
deriveSafeCopy 0 'base ''ProtoIdea
deriveSafeCopy 0 'base ''ProtoIdeaLike
deriveSafeCopy 0 'base ''ProtoIdeaVote
deriveSafeCopy 0 'base ''ProtoTopic
deriveSafeCopy 0 'base ''ProtoUser
deriveSafeCopy 0 'base ''Role
deriveSafeCopy 0 'base ''SchoolClass
deriveSafeCopy 0 'base ''Topic
deriveSafeCopy 0 'base ''UpDown
deriveSafeCopy 0 'base ''User
deriveSafeCopy 0 'base ''UserFirstName
deriveSafeCopy 0 'base ''UserLastName
deriveSafeCopy 0 'base ''UserLogin
deriveSafeCopy 0 'base ''UserPass
deriveSafeCopy 0 'base ''UserSettings


-- * optics

makePrisms ''AUID
makePrisms ''Category
makePrisms ''PlainDocument
makePrisms ''DScope
makePrisms ''Document
makePrisms ''EmailAddress
makePrisms ''IdeaJuryResultValue
makePrisms ''IdeaLocation
makePrisms ''IdeaSpace
makePrisms ''IdeaVoteResultValue
makePrisms ''IdeaVoteValue
makePrisms ''Freeze
makePrisms ''PhaseStatus
makePrisms ''Phase
makePrisms ''Role
makePrisms ''Timestamp
makePrisms ''UpDown
makePrisms ''UserFirstName
makePrisms ''UserLastName
makePrisms ''UserLogin
makePrisms ''UserPass
makePrisms ''UserView

makeLenses ''AUID
makeLenses ''Category
makeLenses ''Comment
makeLenses ''CommentContext
makeLenses ''CommentKey
makeLenses ''CommentVote
makeLenses ''CommentVoteKey
makeLenses ''Delegation
makeLenses ''DelegationNetwork
makeLenses ''DScope
makeLenses ''EmailAddress
makeLenses ''EncryptedPassword
makeLenses ''Freeze
makeLenses ''GMetaInfo
makeLenses ''Idea
makeLenses ''IdeaJuryResult
makeLenses ''IdeaLike
makeLenses ''IdeaLocation
makeLenses ''IdeaSpace
makeLenses ''IdeaVote
makeLenses ''IdeaVoteLikeKey
makeLenses ''IdeaVoteResult
makeLenses ''InitialPassword
makeLenses ''Phase
makeLenses ''PhaseStatus
makeLenses ''PlainDocument
makeLenses ''ProtoIdea
makeLenses ''ProtoIdeaLike
makeLenses ''ProtoIdeaVote
makeLenses ''ProtoTopic
makeLenses ''ProtoUser
makeLenses ''Role
makeLenses ''SchoolClass
makeLenses ''Topic
makeLenses ''UpDown
makeLenses ''User
makeLenses ''UserFirstName
makeLenses ''UserLastName
makeLenses ''UserLogin
makeLenses ''UserPass
makeLenses ''UserSettings
makeLenses ''UserView

-- | Examples:
--
-- >>>    e :: EmailAddress
-- >>>    s :: ST
-- >>>    s = emailAddress # e
-- >>>
-- >>>    s :: ST
-- >>>    s = "foo@example.com"
-- >>>    e :: Maybe EmailAddress
-- >>>    e = s ^? emailAddress
--
-- These more limited type signatures are also valid:
--
-- >>>    emailAddress :: Prism' ST  EmailAddress
-- >>>    emailAddress :: Prism' LBS EmailAddress
emailAddress :: (CSI s t SBS SBS) => Prism s t EmailAddress EmailAddress
emailAddress = csi . prism' Email.toByteString Email.emailAddress . from _InternalEmailAddress


-- * json

instance Aeson.ToJSON (AUID a) where toJSON = Aeson.gtoJson
instance Aeson.ToJSON CommentKey where toJSON = Aeson.gtoJson
instance Aeson.ToJSON DScope where toJSON = Aeson.gtoJson
instance Aeson.ToJSON Delegation where toJSON = Aeson.gtoJson
instance Aeson.ToJSON EmailAddress where toJSON = Aeson.String . review emailAddress
instance Aeson.ToJSON Freeze where toJSON = Aeson.gtoJson
instance Aeson.ToJSON id => Aeson.ToJSON (GMetaInfo a id) where toJSON = Aeson.gtoJson
instance Aeson.ToJSON IdeaJuryResultType where toJSON = Aeson.gtoJson
instance Aeson.ToJSON IdeaLocation where toJSON = Aeson.gtoJson
instance Aeson.ToJSON IdeaSpace where toJSON = Aeson.gtoJson
instance Aeson.ToJSON IdeaVoteValue where toJSON = Aeson.gtoJson
instance Aeson.ToJSON Phase where toJSON = Aeson.gtoJson
instance Aeson.ToJSON PhaseStatus where toJSON = Aeson.gtoJson
instance Aeson.ToJSON Role where toJSON = Aeson.gtoJson
instance Aeson.ToJSON SchoolClass where toJSON = Aeson.gtoJson
instance Aeson.ToJSON UpDown where toJSON = Aeson.gtoJson
instance Aeson.ToJSON UserFirstName where toJSON = Aeson.gtoJson
instance Aeson.ToJSON UserLastName where toJSON = Aeson.gtoJson
instance Aeson.ToJSON UserLogin where toJSON = Aeson.gtoJson
instance Aeson.ToJSON UserPass where toJSON _ = Aeson.String ""
    -- FIXME: where do we need this?  think of something else!
instance Aeson.ToJSON UserSettings where toJSON = Aeson.gtoJson
instance Aeson.ToJSON User where toJSON = Aeson.gtoJson

instance Aeson.FromJSON (AUID a) where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON CommentKey where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON DScope where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON Delegation where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON EmailAddress where parseJSON = Aeson.withText "email address" $ pure . (^?! emailAddress)
instance Aeson.FromJSON Freeze where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON id => Aeson.FromJSON (GMetaInfo a id) where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON IdeaJuryResultType where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON IdeaLocation where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON IdeaSpace where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON IdeaVoteValue where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON Phase where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON PhaseStatus where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON Role where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON SchoolClass where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON UpDown where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON UserFirstName where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON UserLastName where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON UserLogin where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON UserPass where parseJSON _ = pure . UserPassInitial $ InitialPassword ""
    -- FIXME: where do we need this?  think of something else!
instance Aeson.FromJSON UserSettings where parseJSON = Aeson.gparseJson
instance Aeson.FromJSON User where parseJSON = Aeson.gparseJson


instance Aeson.ToJSON DelegationNetwork where
    toJSON (DelegationNetwork nodes links) = result
      where
        result = Aeson.object
            [ "nodes" Aeson..= array (renderNode <$> nodes)
            , "links" Aeson..= array (renderLink <$> links)
            ]

        -- FIXME: It shouldn't be rendered for deleted users.
        renderNode (u, p) = Aeson.object
            [ "name"   Aeson..= (u ^. userLogin . unUserLogin)
            , "avatar" Aeson..= (u ^. userAvatar avatarDefaultSize)
            , "power"  Aeson..= p
            ]

        renderLink (Delegation _ u1 u2) = Aeson.object
            [ "source"  Aeson..= nodeId u1
            , "target"  Aeson..= nodeId u2
            ]

        -- the d3 edges refer to nodes by list position, not name.  this function gives the list
        -- position.
        nodeId :: AUID User -> Aeson.Value
        nodeId uid = Aeson.toJSON . (\(Just pos) -> pos) $ Map.lookup uid m
          where
            m :: Map.Map (AUID User) Int
            m = Map.unions $ List.zipWith f nodes [0..]

            f :: (User, Int) -> Int -> Map.Map (AUID User) Int
            f (u, _) = Map.singleton (u ^. to _userMeta . to _metaKey)

        array :: Aeson.ToJSON v => [v] -> Aeson.Value
        array = Aeson.Array . Vector.fromList . fmap Aeson.toJSON
