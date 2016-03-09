{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-orphans #-}

module Frontend.PathSpec
where

import Data.String.Conversions (cs)
import Data.Typeable (Typeable, typeOf)
import Test.Hspec (Spec, beforeAll, describe, it)
import Test.QuickCheck (Arbitrary, Gen, forAll, property)
import qualified Data.Text as ST

import Arbitrary
import Data.UriPath
import Frontend
import Frontend.Core
import Frontend.Path
import Types

import Servant
import Servant.HTML.Lucid
import Servant.Mock (HasMock(..), mock)
import Servant.Missing hiding (redirect)
import Network.Wai

import Test.Hspec.Wai (get, shouldRespondWith)
import qualified Test.Hspec.Wai.QuickCheck as Wai (property)

spec :: Spec
spec = do

    describe "HasPath" $ do
        it "absoluteUriPath is not empty and well defined" . property . forAll mainGen $ \path ->
            ST.length (absoluteUriPath $ relPath path) >= 1
        it "relativeUriPath is not empty and well defined" . property . forAll mainGen $ \path ->
            ST.length (relativeUriPath $ relPath path) >= 0

    describe "FromHttpApiData <-> UriPath" $ do
        mapM_ uriPartAndHttpApiDataAreInverses
            [ U (arb :: Gen PermissionContext)
            , U (arb :: Gen IdeaSpace)
            ]

    describe "Paths and handlers" $ do
        beforeAll mockAulaTop $ do
            it "Every path has a correspondence handler" $ \app -> property . forAll mainGen $ \path ->
                flip Wai.property app $ do
                    get (cs . absoluteUriPath $ relPath path) `shouldRespondWith` 200

  where
    mainGen :: Gen Main
    mainGen = arbitrary

-- * UriPath and FromHttpApiData correspondence

data UriPartGen where
    U :: (Show d, Typeable d, FromHttpApiData d, HasUriPart d, Eq d) =>
        Gen d -> UriPartGen

uriPartAndHttpApiDataAreInverses :: UriPartGen -> Spec
uriPartAndHttpApiDataAreInverses (U g) =
    it (show $ typeOf g) . property . forAll g $ \uriPartData ->
        (Right uriPartData ==) . parseUrlPiece . cs $ uriPart uriPartData

-- * All Paths has a handler

mockAulaTop :: IO Application
mockAulaTop = do
    return $ serve (Proxy :: Proxy AulaTop) (mock (Proxy :: Proxy AulaTop))

instance Arbitrary a => HasMock (FormReqBody :> Post '[Servant.HTML.Lucid.HTML] (FormPage a)) where
    mock _ _ = mock (Proxy :: Proxy (Post '[Servant.HTML.Lucid.HTML] (FormPage a)))
