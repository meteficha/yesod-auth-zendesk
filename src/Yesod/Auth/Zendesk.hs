{-# OPTIONS_GHC -fno-warn-orphans #-}
module Yesod.Auth.Zendesk
    ( YesodZendesk(..)
    , ZendeskUser(..)
    , ZendeskExternalId(..)
    , Zendesk
    , getZendesk
    , zendeskLoginRoute
    ) where

import Control.Applicative ((<$>))
import Control.Monad (join)
import Data.Default (Default(..))
import Data.List (intersperse)
import Data.Text (Text)
import Data.Time (getCurrentTime, formatTime)
import Yesod.Auth
import Yesod.Core
import qualified Crypto.Hash.MD5 as MD5
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Base16 as Base16
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as H
import qualified Network.Wai as W

import Yesod.Auth.Zendesk.Data


-- | Type class that you need to implement in order to support
-- Zendesk remote authentication.
--
-- /Minimal complete definition:/ all functions are required.
class YesodAuthPersist site => YesodZendesk site where
  -- | Shared secret between Zendesk and your site.
  zendeskToken :: site -> B.ByteString

  -- | URL on your Zendesk's site where users should be
  -- redirected to when logging in.
  zendeskAuthURL :: site -> Text

  -- | Gather information that should be given to Zendesk about
  -- an user.  Please see 'ZendeskUser' for more information
  -- about what these fields mean.
  --
  -- Simple example:
  --
  -- @
  -- zendeskUserInfo = do
  --   Entity uid user <- 'requireAuth'
  --   return 'def' { 'zuName'  = userName user
  --              , 'zuEmail' = userEmail user }
  -- @
  --
  -- Advanced example:
  --
  -- @
  -- zendeskUserInfo = do
  --   uid <- 'requireAuthId'
  --   render <- 'getUrlRender'
  --   runDB $ do
  --     Just user <- get uid
  --     Just org  <- get (userOrganization user)
  --     return 'def' { 'zuName'           = userName user
  --                , 'zuEmail'          = userEmail user
  --                , 'zuOrganization'   = Just (organizationName org)
  --                , 'zuRemotePhotoURL' = Just (render $ UserPhotoR uid)
  --                }
  -- @
  --
  -- /Note:/ although I don't recomend this and I don't see any
  -- reason why you would do it, it /is/ possible to use
  -- 'maybeAuth' instead of 'requireAuth' and login on Zendesk
  -- with some sort of guest user should the user not be logged
  -- in.
  zendeskUserInfo :: HandlerT site IO ZendeskUser


-- | Information about a user that is given to 'Zendesk'.  Please
-- see Zendesk's documentation
-- (<http://www.zendesk.com/support/api/remote-authentication>)
-- in order to see more details of how theses fields are
-- interpreted.
--
-- Only 'zuName' and 'zuEmail' are required.
data ZendeskUser =
  ZendeskUser
    { zuName :: Text
    -- ^ User name, at least two characters. (required)
    , zuEmail :: Text
    -- ^ E-mail address. (required)
    , zuExternalId :: ZendeskExternalId
    -- ^ An external (to Zendesk) ID that identifies this user.
    -- Defaults to 'UseYesodAuthId'.
    , zuOrganization :: Maybe Text
    -- ^ Organization the user belongs to.
    , zuTags :: [Text]
    -- ^ List of tags.
    , zuRemotePhotoURL :: Maybe Text
    -- ^ Public URL with the user's profile picture.
    } deriving (Eq, Ord, Show, Read)

-- | Fields 'zuName' and 'zuEmail' are required, so 'def' will be
-- 'undefined' for them.
instance Default ZendeskUser where
  def = ZendeskUser
          { zuName  = error "ZendeskUser's zuName is a required field."
          , zuEmail = error "ZendeskUser's zuEmail is a required field."
          , zuExternalId     = def
          , zuOrganization   = Nothing
          , zuTags           = []
          , zuRemotePhotoURL = Nothing
          }


-- | Which external ID should be given to Zendesk.
data ZendeskExternalId =
    UseYesodAuthId
    -- ^ Use the user ID from @persistent@\'s database.  This is
    -- the recommended and default value.
  | Explicit Text
    -- ^ Use this given value.
  | NoExternalId
    -- ^ Do not give an external ID.
    deriving (Eq, Ord, Show, Read)

-- | Default is 'UseYesodAuthId'.
instance Default ZendeskExternalId where
  def = UseYesodAuthId


----------------------------------------------------------------------


-- | Create a new 'Zendesk', use this on your @config/routes@ file.
getZendesk :: a -> Zendesk
getZendesk = const Zendesk


instance YesodZendesk site => YesodSubDispatch Zendesk (HandlerT site IO) where
  yesodSubDispatch = $(mkYesodSubDispatch resourcesZendesk)


-- | Redirect the user to Zendesk such that they're already
-- logged in when they arrive.  For example, you may use
-- @zendeskLoginRoute@ when the user clicks on a \"Support\" item
-- on a menu.
zendeskLoginRoute :: Route Zendesk
zendeskLoginRoute = ZendeskLoginR


-- | Route used by the Zendesk remote authentication.  Works both
-- when Zendesk call us and when we call them.
getZendeskLoginR :: YesodZendesk site => HandlerT Zendesk (HandlerT site IO) ()
getZendeskLoginR = do
  -- Get the timestamp and the request params.
  (timestamp, getParams) <- do
    rawReqParams <- W.queryString <$> waiRequest
    case join $ lookup "timestamp" rawReqParams of
      Nothing -> do
        -- Doesn't seem to be a request from Zendesk, create our
        -- own timestamp.
        now <- liftIO getCurrentTime
        let timestamp = B8.pack $ formatTime locale "%s" now
            locale = error "yesod-auth-zendesk: never here (locale not needed)"
        return (timestamp, [("timestamp", Just timestamp)])
      Just timestamp ->
        -- Seems to be a request from Zendesk.
        --
        -- They ask us to reply to them with all the request
        -- parameters they gave us, and at first it seems that
        -- this could create a security problem: we can't confirm
        -- that the request really came from Zendesk, and a
        -- malicious person could include a parameter such as
        -- "email=foo@bar.com".  These attacks would foiled by
        -- the hash, however.
        return (timestamp, rawReqParams)

  -- Get information about the currently logged user.
  ZendeskUser {..} <- lift zendeskUserInfo
  externalId <- case zuExternalId of
                  UseYesodAuthId -> Just . toPathPiece <$> lift requireAuthId
                  Explicit x     -> return (Just x)
                  NoExternalId   -> return Nothing
  let tags = T.concat $ intersperse "," zuTags

  -- Calculate hash
  y <- lift getYesod
  let hash =
        let toBeHashed = B.concat .  cons zuName
                                  .  cons zuEmail
                                  . mcons externalId
                                  . mcons zuOrganization
                                  .  cons tags
                                  . mcons zuRemotePhotoURL
                                  .  (:)  (zendeskToken y)
                                  .  (:)  timestamp
                                  $[]
            cons  = (:) . TE.encodeUtf8
            mcons = maybe id cons
        in Base16.encode $ MD5.hash toBeHashed

  -- Encode information into parameters
  let addParams = paramT  "name"             (Just zuName)
                . paramT  "email"            (Just zuEmail)
                . paramBS "hash"             (Just hash)
                . paramT  "external_id"      externalId
                . paramT  "organization"     zuOrganization
                . paramT  "tags"             (Just tags)
                . paramT  "remote_photo_url" zuRemotePhotoURL
        where
          paramT name = paramBS name . fmap TE.encodeUtf8
          paramBS name (Just t) | not (B.null t) = (:) (name, Just t)
          paramBS _    _                         = id
      params = H.renderQuery True {- add question mark -} $
               addParams getParams

  -- Redirect to Zendesk
  redirect $ zendeskAuthURL y `T.append` TE.decodeUtf8 params
