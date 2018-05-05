{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeFamilies #-}
-- import Test.HUnit
import Test.Hspec
import qualified Test.Hspec.Snap as Test
import           Snap.Core
import Snap.Snaplet
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString.Char8 as B
import Snap.Snaplet.Auth
import Database.Persist as P
import Database.Persist.Sql
import Snap.Snaplet.Persistent
import Database.Esqueleto
import Data.Either
import Data.Text as T
import Data.List as L
import Data.Aeson
import Data.Maybe as M
import Data.Aeson.Types
import Data.Time
import Data.Time.Clock.POSIX

import Test.Helpers as H
import Services.Service as S
import Services.DatabaseHelpers as DBH
import Services.Types
import qualified Test.Fixtures as Fix

import qualified Application as AppMain

-- testAverage = 3 ~?= (5 :: Int)

-- foo :: Int -> Int
-- foo x = 4

-- t = TestCase $ assertEqual "foo" 1 (foo 2)

-- -- padEvals :: Int -> GameResult -> [(Int, Int)] -> [(Int, Int)]

-- testPadWin = actual ~?= expected
--   where actual = Helpers.padEvals 3 Helpers.Win [(1,100), (2, 400)]
--         expected = [(1, 100), (2, Helpers.maxEval), (3, Helpers.maxEval)]

-- testPadLose = actual ~?= expected
--   where actual = Helpers.padEvals 4 Helpers.Lose [(1,100), (2, 200)]
--         expected = [(1, 100), (2, 200), (3, - Helpers.maxEval), (4, - Helpers.maxEval)]

-- tests = TestList ["Padding win" ~: testPadWin, "Padding lose" ~: testPadLose]
main = do
  hspec $ do
    helperTest
    testApi

dbName :: String
dbName = "test"



registerTestUser :: Handler AppMain.App AppMain.App (Either AuthFailure AuthUser)
registerTestUser = do
  user <- with AppMain.auth $ registerUser (B.pack "hi") (B.pack "you")
  return user


userName = "testUser2" :: B.ByteString
params = Test.params [("login", userName), ("password", "password")]

loginForApi userName = do 
  S.createAppUser $ T.pack userName
  S.changeUser (Just userName)

parseDB :: Test.TestResponse -> Maybe [Entity Database]
parseDB (Test.Json _ bs) = decode bs
parseDB _ = Nothing

parseGameData :: Test.TestResponse -> Maybe [GameDataFormatted]
parseGameData (Test.Json _ bs) = decode bs
parseGameData _ = Nothing

keyInt :: PersistValue -> Maybe Int
keyInt (PersistInt64 a) = Just $ fromIntegral a
keyInt _ = Nothing

dbKeyInt :: P.PersistEntity a => Key a -> Int
dbKeyInt key = L.head $ catMaybes $ fmap keyInt $ P.keyToValues key

dbKey :: P.PersistEntity a => Entity a -> Int
dbKey = dbKeyInt . P.entityKey
-- dbKey val = L.head $ catMaybes $ fmap keyInt $ (P.keyToValues . P.entityKey) val

doIO :: IO ()
doIO = do
  let runEval = True
  let onlyContinueEval = False
  let dbName = "test"
  let settings = Fix.Settings dbName runEval onlyContinueEval
  Fix.runJob settings
  return ()

defaultDBName = "game.pgn"

getTimeInt :: IO Int
getTimeInt = getCurrentTime >>= pure . (1000*) . utcTimeToPOSIXSeconds >>= pure . round

getTimeString = fmap show getTimeInt

getDefaultDBId = fmap (P.entityKey . L.head) $ liftIO $ H.inBackend (DBH.connString dbName) $ do selectList [(P.==.) DatabaseName defaultDBName] []


helperTest :: Spec
helperTest = Test.snap (route S.chessRoutes) (S.serviceInit dbName) $ do 
    describe "In the testing functions," $ do
      it "the loginForApi actually changes the current user" $ do
        username <- liftIO $ getTimeString
        Test.eval $ loginForApi username
        user <- Test.eval S.currentUserName
        Test.shouldEqual (Just username) user

testApi :: Spec
-- testApi = Test.snap (route S.chessRoutes) (S.serviceInit dbName) $ beforeAll_ doIO $ do
testApi = Test.snap (route S.chessRoutes) (S.serviceInit dbName) $ do 
  describe "In the database functions," $ do
    it "the databases function returns the right results" $ do
      -- Logging in as a new user that doesn't own any databases
        username <- liftIO $ getTimeString
        Test.eval $ loginForApi username
        Test.eval S.nothingHandler
        res <- Test.eval S.getDatabases
        liftIO $ print "DATABAES RECEIVED"
        liftIO $ print res
        dbDatabases :: [Entity Database] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [(P.==.) DatabaseIsPublic True] []
        Test.shouldEqual (L.length res) (L.length dbDatabases)

    it "the eval averages are returned for every player" $ do
      defaultDBId <- getDefaultDBId
      players :: [Entity Player] <- liftIO $ H.inBackend (DBH.connString dbName) $ do selectList [(P.==.) PlayerDatabaseId defaultDBId] []
      dbGames :: [Entity Game] <- liftIO $ H.inBackend (DBH.connString dbName) $ do selectList [(P.==.) GameDatabaseId defaultDBId] []
      res <- Test.eval $ S.getResultByEvaluation $ fmap dbKey dbGames
      Test.shouldEqual (L.length res) (L.length players)

    it "one should only get games for the private databases that a user owns" $ do
      let userName = "testUser" :: String
      let backendInsert row = liftIO $ H.inBackend (DBH.connString dbName) $ P.insert $ row
      Test.eval $ loginForApi userName
      user <- fmap (maybe "" id) $ Test.eval S.currentUserName
      dbTime <- liftIO $ getTimeInt
      db <- backendInsert $ Database ("temp" ++ show dbTime) False
      dbp <- backendInsert $ DatabasePermission db user True True True
      p <- backendInsert $ Player db "temp" "temp"
      t <- backendInsert $ Tournament db "temp"
      game <- backendInsert $ Game db p p 1 t "" Nothing
      ga <- backendInsert $ GameAttribute game "test" "test"
      let request = S.getGames $ GameRequestData (dbKeyInt db) []
      games :: [GameDataFormatted] <- Test.eval request
      Test.shouldEqual (L.length games) 1 

      Test.eval $ loginForApi "temp2"
      gamesForNewUser <- Test.eval request
      Test.shouldEqual (L.length gamesForNewUser) 0

  describe "In the API," $ do
    it "databases should return what's public in the table" $ do 
      -- Logging in as a user that doesn't own any databases
      username <- liftIO $ getTimeString
      Test.eval $ loginForApi username
      Test.eval S.nothingHandler
      res <- Test.get "/databases"
      let apiDatabases = parseDB res
      dbDatabases :: [Entity Database] <- liftIO $ H.inBackend (DBH.connString dbName) $ do selectList [(P.==.) DatabaseIsPublic True] []
      let values = maybe [] id apiDatabases
      Test.shouldEqual (L.length values) (L.length dbDatabases)

    it "a bad URL should 404" $ do
      Test.get "/badApi" >>= Test.should404
    it "It should not return a user if no user is set" $ do
      let userName = "testUser"
      res <- Test.get "/user"
      let isFound = L.isInfixOf userName $ show res
      Test.shouldNotBeTrue isFound
    it "It should return a user if it is set" $ do
      let userName = "testUser" :: String
      Test.eval $ loginForApi userName
      res <- Test.get "/user"
      let isFound = L.isInfixOf userName $ show res
      Test.shouldBeTrue isFound
    describe "If I query the /games endpoint then" $ do
      it "it doesn't return anything for a non-existent database" $ do
        dbDatabases :: [Entity Database] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [] []
        dbTournaments :: [Entity Tournament] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [] []
        let nonExistingDB = (L.maximum (fmap dbKey dbTournaments)) + 1
        let tournamentIds = fmap dbKey dbTournaments
        let requestData = Test.params $ [("gameRequestDB", B.pack (show nonExistingDB)), ("gameRequestTournaments", B.pack (show tournamentIds))]
        res <- Test.post "/games" requestData
        let values = maybe [] id $ parseGameData res
        Test.shouldEqual (L.length values) 0

      it "it does return values for a database that has games" $ do
        dbDatabases :: [Entity Database] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [] []
        dbTournaments :: [Entity Tournament] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [] []
        dbGames :: [Entity Game] <- liftIO $ H.inBackend (DBH.connString dbName) $ do
          selectList [] []
        let firstGame = L.head dbGames 
        let gamesForDB = L.filter (\v -> (gameDatabaseId (entityVal v) == gameDatabaseId (entityVal firstGame))) dbGames
        let firstGameInt = L.head $ catMaybes $ fmap keyInt $ P.keyToValues $ gameDatabaseId $ entityVal $ firstGame
        let tournamentIds = fmap dbKey dbTournaments

        let requestData = GameRequestData firstGameInt tournamentIds
        res <- Test.postJson "/games" requestData
        Test.should200 res
        let values = maybe [] id $ parseGameData res
        Test.shouldEqual (L.length values) (L.length gamesForDB)

tests :: Spec
tests = Test.snap (route AppMain.routes) (AppMain.app dbName) $ do
          describe "Application" $ do
            it "Register should 200" $ do
              Test.post "/register" params >>= Test.should200

runWithLogin :: String -> String -> Handler b b () -> Handler b b ()
runWithLogin name password handler = do
  x <- handler
  return ()
  
  
        
            
-- Tests
-- If I am logged in and I upload a database, I can read it
-- I log out, log in as another user. Then I can't read the database
-- I can always read public databases, but I can't write to them
--
--


-- main :: IO ()
-- main = do
--   print ("testing" :: String)
--   runTestTT tests
--   return ()
