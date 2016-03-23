{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-missing-signatures -fno-warn-incomplete-patterns #-}

module Frontend.CoreSpec where

import Control.Arrow((&&&))
import Control.Monad.Trans.Except
import Data.List
import Data.String.Conversions
import Data.Typeable (typeOf)
import Servant.Server.Internal.ServantErr
import Test.QuickCheck (Arbitrary(..), Gen, forAll, property)
import Test.QuickCheck.Monadic (assert, monadicIO, run, pick)
import Text.Digestive.Types
import Text.Digestive.View

import qualified Data.Text.Lazy as LT
import qualified Text.Digestive.Lucid.Html5 as DF

import Action
import Action.Implementation
import Arbitrary (arb, arbPhrase, schoolClasses)
import Config (Config, devel)
import Frontend.Core
import Frontend.Page
import qualified Persistent.Implementation.STM
import Types

import AulaTests


-- * list all types for testing

spec :: Spec
spec = do
    context "ToHtml" $ mapM_ renderMarkup [
          H (arb :: Gen PageRoomsOverview)
        , H (arb :: Gen PageIdeasOverview)
        , H (arb :: Gen PageIdeasInDiscussion)
        , H (arb :: Gen ViewTopic)
        , H (arb :: Gen ViewIdea)
        , H (arb :: Gen PageUserProfileCreatedIdeas)
        , H (arb :: Gen PageUserProfileDelegatedVotes)
        , H (arb :: Gen PageAdminSettingsGaPUsersView)
        , H (arb :: Gen PageAdminSettingsGaPUsersCreate)
        , H (arb :: Gen PageAdminSettingsGaPClassesView)
        , H (arb :: Gen PageAdminSettingsEventsProtocol)
        , H (arb :: Gen PageDelegateVote)
        , H (arb :: Gen PageDelegationNetwork)
        , H (arb :: Gen PageStaticImprint)
        , H (arb :: Gen PageStaticTermsOfUse)
        , H (arb :: Gen PageAdminSettingsGaPClassesEdit)
        , H (PageComment <$> arb)
        ]
    context "PageFormView" $ mapM_ testForm [
--          F (arb :: Gen CreateIdea)  -- FIXME
          F (arb :: Gen EditIdea)
        , F (arb :: Gen PageHomeWithLoginPrompt)
        , F (arb :: Gen CreateTopic)
        , F (arb :: Gen PageUserSettings)
        , F (arb :: Gen EditTopic)
        , F (arb :: Gen PageAdminSettingsDurations)
        , F (arb :: Gen PageAdminSettingsQuorum)
--        , F (arb :: Gen PageAdminSettingsGaPUsersEdit) -- FIXME
        ]


-- * translate form data back to form input

-- | Translate a value into the select string for the form 'Env'.
--
-- FIXME: none of this is very elegant.  can we improve on it?
-- FIXME: this function does not work for complex ADTs. E.g: 'SchoolClass Int String'
--
-- Text fields in forms are nice because the values in the form 'Env' contains simply the text
-- itself, as it ends up in the parsed form playload.  Selections (pull-down menus) are trickier,
-- because 'Env' maps their path to an internal representation of a reference to the selected item,
-- rather than the human-readable menu entry.
--
-- This function mimics the 'inputSelect' functions internal behavior from the
-- digestive-functors-lucid package: it extracts an enumeration of the input choices from the views,
-- constructs the form field values from that, and looks up the one whose item description matches
-- the given category value.
--
-- Since the item descriptions are available only as 'Html', not as text, and 'Html' doesn't have
-- 'Eq', we need to apply another trick and transform both the category value and the item
-- description to 'LT'.
selectValue :: Eq a => ST -> View (Html ()) -> [(a, LT.Text)] -> a -> ST
selectValue ref v xs x = case find test choices of Just (i, _, _) -> value i
  where
    ref'    = absoluteRef ref v
    value i = ref' <> "." <> i
    choices = fieldInputChoice ref v
    test (_, sx :: Html (), _) = showValue x == renderText sx
    showValue ((`lookup` xs) -> Just y) = y

-- | In order to be able to call 'payloadToEnvMapping, define a `PayloadToEnv' instance.
class PayloadToEnv a where
    payloadToEnvMapping :: View (Html ()) -> a -> ST -> Action r [FormInput]

-- | When context dependent data is constructed via forms with the 'pure' combinator
-- in the form description, in the digestive functors libarary an empty path will
-- be generated. Which is not an issue here. This functions guards against that with
-- the @[""]@ case.
--
-- Example:
--
-- >>> ProtoIdea <$> ... <*> pure ScoolSpave <*> ...
payloadToEnv :: (PayloadToEnv a) => View (Html ()) -> a -> Env (Action r)
payloadToEnv _ _ [""]       = pure []
payloadToEnv v a ["", path] = payloadToEnvMapping v a path

instance PayloadToEnv ProtoIdea where
    payloadToEnvMapping _v (ProtoIdea t (Markdown d) c _is) = \case
        "title"         -> pure [TextInput t]
        "idea-text"     -> pure [TextInput d]
        "idea-category" -> pure [TextInput . cs . show . fromEnum $ c]

instance PayloadToEnv LoginFormData where
    payloadToEnvMapping _ (LoginFormData name pass) = \case
        "user" -> pure [TextInput name]
        "pass" -> pure [TextInput pass]

ideaCheckboxValue iids path =
    if path `elem` (("idea-" <>) . show <$> iids)
        then "on"
        else "off"

instance PayloadToEnv ProtoTopic where
    payloadToEnvMapping _ (ProtoTopic title (Markdown desc) image _ iids) path'
        | "idea-" `isPrefixOf` path = pure [TextInput $ ideaCheckboxValue iids path]
        | path == "title" = pure [TextInput title]
        | path == "desc"  = pure [TextInput desc]
        | path == "image" = pure [TextInput image]
      where
        path :: String = cs path'

instance PayloadToEnv TopicFormPayload where
    payloadToEnvMapping _ (TopicFormPayload title (Markdown desc) iids) path'
        | "idea-" `isPrefixOf` path = pure [TextInput $ ideaCheckboxValue iids path]
        | path == "title"           = pure [TextInput title]
        | path == "desc"            = pure [TextInput desc]
      where
        path :: String = cs path'

instance PayloadToEnv UserSettingData where
    payloadToEnvMapping _ (UserSettingData email oldpass newpass1 newpass2) = \case
        "email"         -> pure [TextInput . fromMaybe "" $ fromUserEmail <$> email]
        "old-password"  -> pure [TextInput $ fromMaybe "" oldpass]
        "new-password1" -> pure [TextInput $ fromMaybe "" newpass1]
        "new-password2" -> pure [TextInput $ fromMaybe "" newpass2]

instance PayloadToEnv Durations where
    payloadToEnvMapping _ (Durations elab vote) = \case
        "elab-duration" -> pure [TextInput (cs . show . fromDurationDays $ elab)]
        "vote-duration" -> pure [TextInput (cs . show . fromDurationDays $ vote)]

instance PayloadToEnv Quorums where
    payloadToEnvMapping _ (Quorums school clss) = \case
        "school-quorum" -> pure [TextInput (cs $ show school)]
        "class-quorum"  -> pure [TextInput (cs $ show clss)]

instance PayloadToEnv EditUserPayload where
    payloadToEnvMapping v (EditUserPayload r c) = \case
        "user-role"  -> pure [TextInput $ selectValue "user-role" v roleSelectionChoices r]
        -- FIXME: Selection does not work for composite types like school class.
        "user-class" -> pure [TextInput $ selectValue "user-class" v classes c]
      where
        classes = (id &&& cs . view className) <$> schoolClasses


-- * machine room

data HtmlGen where
    H :: (Show m, Typeable m, ToHtml m) => Gen m -> HtmlGen

-- | Checks if the markup rendering does not contains bottoms.
renderMarkup :: HtmlGen -> Spec
renderMarkup (H g) =
    it (show $ typeOf g) . property . forAll g $ \pageSource ->
        LT.length (renderText (toHtml pageSource)) > 0

data FormGen where
    F :: ( r ~ FormPagePayload m
         , Show m, Typeable m, FormPage m
         , Show r, Eq r, Arbitrary r, PayloadToEnv r
         , ArbFormPagePayload m
         ) => Gen m -> FormGen

testForm :: FormGen -> Spec
testForm fg = renderForm fg >> postToForm fg

-- | Checks if the form rendering does not contains bottoms and
-- the view has all the fields defined for GET form creation.
renderForm :: FormGen -> Spec
renderForm (F g) =
    it (show (typeOf g) <> " (show empty form)") . property . forAll g $ \page -> monadicIO $ do
        len <- run . failOnError $ do
            v <- getForm (absoluteUriPath $ formAction page) (makeForm page)
            return . LT.length . renderText $ formPage v (DF.form v "formAction") page
        assert (len > 0)

-- | Run the given action for testing.
--
-- FUTUREWORK: Abstraction leaks in tests are not dangerous and they don't
-- infect other code, so they are left alone for now, though in the long run,
-- abstraction would improve test code as well (separation of concerns
-- via abstraction).
runAction :: Config -> Action Persistent.Implementation.STM.Persist a -> ExceptT ServantErr IO a
runAction cfg action = do rp <- liftIO Persistent.Implementation.STM.mkRunPersist
                          unNat (mkRunAction (ActionEnv rp cfg)) action

failOnError :: Action Persistent.Implementation.STM.Persist a -> IO a
failOnError = fmap (either (error . show) id) . runExceptT . runAction Config.devel

-- | Checks if the form processes valid and invalid input a valid output and an error page, resp.
--
-- For valid inputs, we generate an arbitrary value of the type generated by the form parser,
-- translate it back into a form 'Env' with a 'PayloadToEnv' instance, feed that into 'postForm',
-- and compare the parsed output with the generated output.
--
-- For invalid inputs, we have to go about it differently: since we don't expect to get a valid form
-- output, we generate an 'Env' directly that can contain anything expressible in a valid HTTP POST
-- request, including illegal or missing form fields, arbitrary invalid string values etc.  This
-- happens in an appropriate 'ArbitraryBadEnv' instance.  For the test to succeed, we compare the
-- errors in the view constructed by 'postForm' against the expected errors generated along with the
-- bad env.
postToForm :: FormGen -> Spec
postToForm (F g) = do
    it (show (typeOf g) <> " (process valid forms)") . property . monadicIO $ do
        page <- pick g
        payload <- pick (arbFormPagePayload page)

        let frm = makeForm page
        env <- run' $ (`payloadToEnv` payload) <$> getForm "" frm

        (_, Just payload') <- run' $ postForm "" frm (\_ -> pure env)
        liftIO $ payload' `shouldBe` payload

    it (show (typeOf g) <> " (process *in*valid form input)") $
        pendingWith "not implemented."  -- FIXME
    where
        run' = run . failOnError

-- | Arbitrary test data generation for the 'FormPagePayload' type.
--
-- In some cases the arbitrary data generation depends on the 'Page' context
-- and the 'FormPagePayload' has to compute data from the context.
class FormPage p => ArbFormPagePayload p where
    arbFormPagePayload :: (r ~ FormPagePayload p, FormPage p, Arbitrary r, Show r) => p -> Gen r

instance ArbFormPagePayload CreateIdea where
    arbFormPagePayload (CreateIdea location) = set protoIdeaLocation location <$> arbitrary

instance ArbFormPagePayload EditIdea where
    arbFormPagePayload (EditIdea idea) = set protoIdeaLocation (idea ^. ideaLocation) <$> arbitrary

instance ArbFormPagePayload PageAdminSettingsQuorum where
    arbFormPagePayload _ = arbitrary

instance ArbFormPagePayload PageAdminSettingsDurations where
    arbFormPagePayload _ = arbitrary

instance ArbFormPagePayload PageUserSettings where
    arbFormPagePayload _ = arbitrary

instance ArbFormPagePayload PageHomeWithLoginPrompt where
    arbFormPagePayload _ = arbitrary

instance ArbFormPagePayload CreateTopic where
    arbFormPagePayload (CreateTopic space ideas) =
            set protoTopicIdeaSpace space
          . set protoTopicIdeas (map (^. _Id) ideas)
        <$> arbitrary

instance ArbFormPagePayload EditTopic where
    arbFormPagePayload (EditTopic _space _topicid ideas) =
        TopicFormPayload
        <$> arbPhrase
        <*> arbitrary
        -- FIXME: Generate a sublist from the given ideas
        -- Ideas should be a set which contains only once one idea. And the random
        -- result generation should select from those ideas only.
        <*> pure (view _Id <$> ideas)

instance ArbFormPagePayload PageAdminSettingsGaPUsersEdit where
    arbFormPagePayload _ = arbitrary
