{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}

{-# OPTIONS_GHC -Werror -Wall -fno-warn-orphans #-}

module Frontend.Core
    ( GetH
    , Page, isPrivatePage
    , PageShow(PageShow)
    , Beside(Beside)
    , Frame(Frame, PublicFrame), makeFrame, pageFrame, pageFrame'
    , FormHandler
    , ListItemIdea(ListItemIdea)
    , FormPageView, FormPageResult
    , formAction, makeForm, formPage, redirectFormHandler
    , RedirectOf, redirectOf
    , AuthorWidget(AuthorWidget)
    , CommentVotesWidget(VotesWidget)
    , semanticDiv
    , showed
    , html
    )
where

import Control.Lens
import Control.Monad.Except (throwError)
import Data.Functor (($>))
import Data.Set (Set)
import Data.String.Conversions
import Data.Typeable
import Data.UriPath (UriPath, absoluteUriPath, href_)
import Lucid hiding (href_)
import Lucid.Base
import Servant
import Servant.HTML.Lucid (HTML)
import Servant.Missing (FormH)
import Text.Digestive.View
import Text.Show.Pretty (ppShow)

import qualified Data.Set as Set
import qualified Text.Digestive.Form as DF

import Action
import Api
import Types

import qualified Frontend.Path as P


-- | FIXME: Could this be a PR for lucid?
instance (ToHtml (HtmlT Identity ())) where
    toHtmlRaw = toHtml
    toHtml = HtmlT . return . runIdentity . runHtmlT


-- | This will generate the following snippet:
--
-- > <div data-aula="PageIdea"> ... </div>
--
-- Which serves two purposes:
--
--     * It helps the front-en developer to identify which part of the generated pages comes from which
--       combinator
--     * Later on when we write selenium suite, the semantic tags helps up to parse, identify and test
--       elements on the page.
semanticDiv :: forall m a. (Monad m, Typeable a) => a -> HtmlT m () -> HtmlT m ()
semanticDiv t = div_ [makeAttribute "data-aula-type" (cs . show . typeOf $ t)]

----------------------------------------------------------------------
-- building blocks

type GetH = Get '[HTML]
type FormHandler p a = FormH HTML (FormPage p) a

-- | Render Form based Views
class FormPageView p where
    type FormPageResult p :: *
    -- | The form action used in form generation
    formAction :: p -> UriPath
    -- | Generates a Html view from the given page
    makeForm :: (Monad m) => p -> DF.Form (Html ()) m (FormPageResult p)
    -- | Generates a Html snippet from the given view, form action, and the @p@ page
    formPage :: (Monad m) => View (HtmlT m ()) -> ST -> p -> HtmlT m ()

-- | Defines some properties for pages
class Page p where
    isPrivatePage :: p -> Bool

-- | The page after submitting a form should be redirected
class RedirectOf p where
    -- | Calculates a redirect address from the given page
    redirectOf :: p -> UriPath

-- | Wrap anything that has 'ToHtml' and wrap it in an HTML body with complete page.
data Frame body = Frame User body | PublicFrame body
  deriving (Functor)

makeFrame :: (ActionPersist m, ActionUserHandler m, Page p) => p -> m (Frame p)
makeFrame p
  | isPrivatePage p = flip Frame p <$> currentUser
  | otherwise       = return $ PublicFrame p

instance (ToHtml body) => ToHtml (Frame body) where
    toHtmlRaw = toHtml
    toHtml (Frame usr bdy)   = pageFrame (Just usr) (toHtml bdy)
    toHtml (PublicFrame bdy) = pageFrame Nothing (toHtml bdy)

pageFrame :: (Monad m) => Maybe User -> HtmlT m a -> HtmlT m ()
pageFrame = pageFrame' []

pageFrame' :: (Monad m) => [HtmlT m a] -> Maybe User -> HtmlT m a -> HtmlT m ()
pageFrame' extraHeaders mUser bdy = do
    head_ $ do
        title_ "AuLA"
        link_ [rel_ "stylesheet", href_ $ P.TopStatic "third-party/Simple-Grid/simplegrid.css"]
        link_ [rel_ "stylesheet", href_ $ P.TopStatic "third-party/HTML5-Reset/assets/css/reset.css"]
        link_ [rel_ "stylesheet", href_ $ P.TopStatic "icons/fontcustom.css"]
        link_ [rel_ "stylesheet", href_ $ P.TopStatic "css/all.css"]
        sequence_ extraHeaders
    body_ $ do
        headerMarkup mUser >> bdy >> footerMarkup

headerMarkup :: (Monad m) => Maybe User -> HtmlT m ()
headerMarkup mUser = header_ [class_ "main-header"] $ do
    span_ [class_ "site-logo", title_ "aula"] $ do
        i_ [class_ "icon-aula-logo site-logo-icon"] ""

    case mUser of
        Just _usr -> do
            ul_ [class_ "main-header-menu"] $ do
                li_ $ a_ [href_ P.ListSpaces] "Ideenräume"
                li_ $ a_ [href_ P.DelegationView] "Beauftragungsnetzwerk"
                li_ $ a_ [href_ P.Logout] "Logout"
        Nothing -> nil

    ul_ [class_ "main-header-user"] $ do
        case mUser of
            Just usr -> do
                li_ (toHtml $ "Hi " <> (usr ^. userLogin))
            Nothing -> nil
        li_ $ img_ [src_ "the_avatar"]


footerMarkup :: (Monad m) => HtmlT m ()
footerMarkup = footer_ [class_ "main-footer"] $ do
    ul_ [class_ "main-footer-menu"] $ do
        li_ $ a_ [href_ P.Terms] "Nutzungsbedingungen"
        li_ $ a_ [href_ P.Imprint] "Impressum"
    span_ [class_ "main-footer-blurb"] "Made with ♡ by Liqd"

html :: (Monad m, ToHtml a) => Getter a (HtmlT m ())
html = to toHtml

showed :: Show a => Getter a String
showed = to show

data Beside a b = Beside a b

instance (ToHtml a, ToHtml b) => ToHtml (Beside a b) where
    toHtmlRaw (x `Beside` y) = toHtmlRaw x <> toHtmlRaw y
    toHtml    (x `Beside` y) = toHtml    x <> toHtml    y

-- | Debugging page, uses the 'Show' instance of the underlying type.
newtype PageShow a = PageShow { _unPageShow :: a }
    deriving (Show)

instance Page (PageShow a) where
    isPrivatePage _ = True

instance Show a => ToHtml (PageShow a) where
    toHtmlRaw = toHtml
    toHtml = pre_ . code_ . toHtml . ppShow . _unPageShow

-- | FIXME: find better name?
newtype CommentVotesWidget = VotesWidget (Set CommentVote)

instance ToHtml CommentVotesWidget where
    toHtmlRaw = toHtml
    toHtml p@(VotesWidget votes) = semanticDiv p . toHtml $ y <> n
      where
        y = "[up: "   <> show (countVotes Up   commentVoteValue votes) <> "]"
        n = "[down: " <> show (countVotes Down commentVoteValue votes) <> "]"

newtype AuthorWidget a = AuthorWidget (MetaInfo a)

instance (Typeable a) => ToHtml (AuthorWidget a) where
    toHtmlRaw = toHtml
    toHtml p@(AuthorWidget mi) = semanticDiv p . span_ $ do
        "["
        img_ [src_ $ mi ^. metaCreatedByAvatar]
        mi ^. metaCreatedByLogin . html
        "]"


data ListItemIdea = ListItemIdea Bool (Maybe Phase) Idea
  deriving (Eq, Show, Read)

instance ToHtml ListItemIdea where
    toHtmlRaw = toHtml
    toHtml p@(ListItemIdea _linkToUserProfile _phase idea) = semanticDiv p $ do
        -- FIXME use the phase
        span_ $ do
            img_ [src_ "some_avatar"]
        span_ $ do
            span_ $ idea ^. ideaTitle . html
            span_ $ "von " <> idea ^. (ideaMeta . metaCreatedByLogin) . html
        span_ $ do
            span_ $ do
                let s = Set.size (idea ^. ideaComments)
                s ^. showed . html
                if s == 1 then "Verbesserungsvorschlag" else "Verbesserungsvorschlaege"
            -- TODO: show how many votes are in and how many are required

-- | HTML representation of a page generated by digestive functors.
data FormPage p = FormPage p (Html ())

instance Page p => Page (FormPage p) where
    isPrivatePage (FormPage p _h) = isPrivatePage p

instance ToHtml (FormPage p) where
    toHtmlRaw = toHtml
    toHtml (FormPage _p h) = toHtml h

redirectFormHandler
    :: (FormPageView p, Page p, RedirectOf p, ActionM m)
    => m p                       -- ^ Page representation
    -> (FormPageResult p -> m a) -- ^ Processor for the form result
    -> ServerT (FormHandler p ST) m
redirectFormHandler getPage processor = getH :<|> postH
  where
    getH = do
        page <- getPage
        let fa = absoluteUriPath $ formAction page
        v <- getForm fa (processor1 page)
        renderer page v fa

    postH env = do
        page <- getPage
        let fa = absoluteUriPath $ formAction page
        (v, mpayload) <- postForm fa (processor1 page) (\_ -> return $ return . runIdentity . env)
        case mpayload of
            Just payload -> processor2 page payload >>= redirect
            Nothing      -> renderer page v fa

    redirect uri = throwError $ err303 { errHeaders = ("Location", cs uri) : errHeaders Servant.err303 }

    -- (possibly interesting: on ghc-7.10.3, inlining `processor1` in the `postForm` call above
    -- produces a type error.  is this a ghc bug, or a bug in our code?)
    processor1 = makeForm
    processor2 page result = processor result $> absoluteUriPath (redirectOf page)
    renderer page v fa = FormPage page . toHtml . fmap (formPage v fa) <$> makeFrame page
