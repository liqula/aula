{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module AulaTests.Stories.DSL where

import Control.Monad.Free
import Data.String.Conversions

import Types


-- * domain model ("the nouns")

type IdeaSpaceName = ST
type IdeaTitle = ST
type IdeaDescription = ST
type TopicTitle = ST
type TopicDescription = ST


-- * the dsl ("the action sentences")

data Step a where
    -- User actions
    Login            :: UserLogin -> a -> Step a
    Logout           :: a -> Step a
    SelectIdeaSpace  :: IdeaSpaceName -> a -> Step a
    CreateIdea       :: IdeaTitle -> IdeaDescription -> Category -> a -> Step a
    LikeIdea         :: IdeaTitle -> a -> Step a
    CreateTopic      :: IdeaTitle -> TopicTitle -> TopicDescription -> a -> Step a

    -- System events, these events probably need a test support, API, etc...
    TimeoutTopic     :: TopicTitle -> a -> Step a
  deriving Functor

type Behavior = Free Step

login :: UserLogin -> Behavior ()
login l = liftF $ Login l ()

logout :: Behavior ()
logout = liftF $ Logout ()

selectIdeaSpace :: IdeaSpaceName -> Behavior ()
selectIdeaSpace n = liftF $ SelectIdeaSpace n ()

createIdea :: IdeaTitle -> IdeaDescription -> Category -> Behavior ()
createIdea title desc cat = liftF $ CreateIdea title desc cat ()

likeIdea :: IdeaTitle -> Behavior ()
likeIdea title = liftF $ LikeIdea title ()

createTopic :: IdeaTitle -> TopicTitle -> TopicDescription -> Behavior ()
createTopic ititle ttitle tdesc = liftF $ CreateTopic ititle ttitle tdesc ()

timeoutTopic :: TopicTitle -> Behavior ()
timeoutTopic title = liftF $ TimeoutTopic title ()
