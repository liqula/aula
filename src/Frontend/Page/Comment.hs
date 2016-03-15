{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}

{-# OPTIONS_GHC -Werror -Wall #-}

-- | ...
--
-- We provide data types @Page...@ even if there is an application type already.  Example: For
-- 'Idea', we define 'PageIdea'.  This has at least two benefits:
--
-- - page types should always be defined here to avoid orphans;
-- - we can add additional information (like author name if we only have an author's id) and thus
--   avoid making page rendering effectful.
module Frontend.Page.Comment
where

import Control.Lens
import Prelude
import Lucid

import Types
import Frontend.Core


data PageComment = PageComment Comment
  deriving (Eq, Show, Read)

instance ToHtml PageComment where
    toHtmlRaw = toHtml
    toHtml p@(PageComment comment) = semanticDiv p $ do
        div_ [class_ "comment"] $ do
            header_ [class_ "comment-header"] $ do
                comment ^. commentMeta . to AuthorWidget . html
                comment ^. commentVotes . to VotesWidget . html
            div_ [class_ "comments-body"] $ do
                comment ^. commentText . html
            footer_ [class_ "comment-footer"] $ do
                div_ [class_ "comment-footer-buttons"] $ do
                    button_ [class_ "btn comment-footer-button"] $ do
                        i_ [class_ "icon-reply"] nil
                        "antworten"
                    button_ [class_ "btn comment-footer-button"] $ do
                        i_ [class_ "icon-flag"] nil
                        "melden"
