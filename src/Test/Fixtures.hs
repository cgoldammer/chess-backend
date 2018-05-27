{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Test.Fixtures where

import Database.Persist (Key, insertBy)
import Database.Persist.Sql 
import qualified Data.Text as Te (Text, pack)
import Data.Either (rights)
import Control.Monad.Trans.Reader (ReaderT)
import Control.Monad.Reader (MonadReader, MonadIO, runReaderT, reader, liftIO)
import Data.Either.Combinators (rightToMaybe)
import Debug.Trace (trace)
import Text.RawString.QQ (r)
import qualified Filesystem.Path.CurrentOS as FS (fromText)
import qualified Turtle as Tu (strict, input, Text)

import Services.Types
import Test.Helpers as Helpers
import Services.DatabaseHelpers as DatabaseHelpers

import qualified Chess.Pgn.Logic as Pgn
import qualified Chess.Logic as Logic

import qualified Chess.Board as Board
import qualified Chess.Stockfish as Stockfish

-- The connection string is obtained from the command line
-- Also, get settings for whether to create fake data.

-- | The settings are obtained from the command line and determine
-- how the data is stored.
-- If the `settingsDelete` flag is set, all data is deleted from the database
-- before data is read in.
-- By default, data is not overwritten. If the program is stopped in the middle of inserting data
-- then running it again should simply continue the data insertion.
--
data Settings = Settings { 
    settingsDBName :: String
  , settingsRunEval :: Bool
  , settingsOnlyContinueEval :: Bool} deriving (Show)

type IsTest = Bool
type OnlyContinue = Bool

data SettingsInput = SettingsInput IsTest OnlyContinue

doNothing :: IO ()
doNothing = do
  return ()

runJob :: Settings -> IO ()
runJob settings = do
  let conn = connString $ settingsDBName settings
  let onlyContinueEval = settingsOnlyContinueEval settings
  if not onlyContinueEval then deleteDBContents conn else doNothing
  runReaderT readerActions settings
  return ()

doNothing' :: ReaderT Settings IO ()
doNothing' = do
  return ()

readerActions :: ReaderT Settings IO ()
readerActions = do
  continue <- reader settingsOnlyContinueEval
  evaluate <- reader settingsRunEval
  if continue 
    then do
      if evaluate then do evaluateGames else doNothing'
    else do
      storeGamesIntoDB
      if evaluate then do evaluateGames else doNothing'
  return ()

getDBType :: String -> IsTest
getDBType "prod" = False
getDBType _ = True

getFiles :: IsTest -> [String]
getFiles True = ["tata2018.pgn"]
getFiles False = ["tata2018.pgn"]

storeGamesIntoDB :: (MonadReader Settings m, MonadIO m) => m ()
storeGamesIntoDB = do
  dbName <- reader settingsDBName
  mapM_ storeFileIntoDB $ getFiles $ getDBType dbName

storeFileIntoDB :: (MonadReader Settings m, MonadIO m) => String -> m [Maybe (Key Game)]
storeFileIntoDB fileName = do
  dbName <- reader settingsDBName
  liftIO $ print $ "Database" ++ show dbName
  (_, res) :: (Key Database, [Maybe (Key Game)]) <- liftIO $ inBackend (connString dbName) $ do
    -- dbResult <- insert (Database fileName True)
    -- liftIO $ print $ "done with creation" ++ show dbResult
    let fullName = "./test/files/" ++ fileName
    fileText :: Te.Text <- Tu.strict $ Tu.input $ FS.fromText $ Te.pack fullName
    DatabaseHelpers.readTextIntoDB dbName fileName fileText True
  return res

evaluateGames :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGames = do
  isTest <- fmap getDBType $ reader settingsDBName
  if isTest then evaluateGamesTest else evaluateGamesReal
  return ()

evaluateGamesReal :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGamesReal = do
  dbName <- reader settingsDBName
  continueEval <- reader settingsOnlyContinueEval
  games <- liftIO $ inBackend (connString dbName) $ do
    dbGames :: [Entity Game] <- getGamesFromDB continueEval
    return dbGames
  let games2 = reverse games
  fmap concat $ mapM doEvaluation games2
  return ()

evaluateGamesTest :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGamesTest = do
  evaluateGamesReal
  return ()

doEvaluation :: (MonadReader Settings m, MonadIO m) => Entity Game -> m [Key MoveEval]
doEvaluation dbGame  = do
  dbName <- reader settingsDBName
  doAndStoreEvaluationIO dbName dbGame


doAndStoreEvaluationIO :: MonadIO m => String -> Entity Game -> m [Key MoveEval]
doAndStoreEvaluationIO dbName dbGame = do
  let maybeGame = trace "Storing evaluations for game" $ dbGameToPGN $ entityVal dbGame
  keys <- case maybeGame of 
    (Just game) -> do
      summaries <- liftIO $ Pgn.gameSummaries game
      keys <- liftIO $ inBackend (connString dbName) $ do
        k <- mapM insertBy $ evalToRow (entityKey dbGame) summaries
        return $ rights k
      return keys
    Nothing ->
      return []
  return keys

-- | Adds structured player ratings to the database.
-- These ratings are already stored in raw format as part of the 
-- `game_tag` table. Here, we turn this raw data into monthly player
-- evaluations. 
-- The monthly evaluation is simply the average of the player's raw rating
-- over all games in a certain month. If a player has not played any games in 
-- a certain month, the `player_rating` table will not contain any data for this month.
-- If you are using this data to report player ratings graphs, you might
-- want to fill in this missing time period with the latest preceding rating.
ratingQuery :: Tu.Text
ratingQuery = [r|
SELECT player_id, extract(year from date) as year, extract(month from date) as month, avg(rating)::Int
FROM (
  SELECT player_black_id as player_id, date, value::Int as rating
  FROM game
  JOIN game_attribute ON game.id=game_attribute.game_id AND attribute='BlackPlayerElo'
  UNION ALL
  SELECT player_white_id as player_id, date, value::Int as rating
  FROM game
  JOIN game_attribute ON game.id=game_attribute.game_id AND attribute='WhitePlayerElo'
) values
GROUP BY player_id, year, month
|]

type RatingQueryType = (Single Int, Single Int, Single Int, Single Int)

intToKey :: Int -> Key Player
intToKey = toSqlKey . fromIntegral

readRatingQuery :: RatingQueryType -> PlayerRating
readRatingQuery (Single player_id, Single year, Single month, Single rating) = PlayerRating (intToKey player_id) year month rating

addRatings :: DataAction ()
addRatings = do
  results :: [RatingQueryType] <- rawSql ratingQuery []
  mapM_ (insertBy . readRatingQuery) results
  return ()
 

sqlGamesAll :: Tu.Text
sqlGamesAll = [r|
SELECT ??
FROM game
|]

sqlGamesUnevaluated :: Tu.Text
sqlGamesUnevaluated = [r|
SELECT ?? 
FROM game
WHERE game.id not in (SELECT DISTINCT game_id from move_eval)
|]

getGamesFromDB :: Bool -> DataAction [Entity Game]
getGamesFromDB continueEval = do
  let query = if continueEval then sqlGamesUnevaluated else sqlGamesAll
  games :: [Entity Game] <- rawSql query []
  return games

evalToRow :: Key Game -> [Pgn.MoveSummary] -> [MoveEval]
evalToRow g ms = evalToRowColor g 1 Board.White ms

evalToRowColor :: Key Game -> Int -> Board.Color -> [Pgn.MoveSummary] -> [MoveEval]
evalToRowColor _ _ _ [] = []
evalToRowColor g n (Board.White) (ms : rest) = constructEvalMove g n True ms : evalToRowColor g n (Board.Black) rest
evalToRowColor g n (Board.Black) (ms : rest) = constructEvalMove g n False ms : evalToRowColor g (n + 1) (Board.White) rest

constructEvalMove :: Key Game -> Int -> Bool -> Pgn.MoveSummary -> MoveEval
constructEvalMove gm n isWhite (Pgn.MoveSummary mv mvBest evalMove _ _ fen) = MoveEval gm n isWhite mvString mvBestString eval mate fen
  where mvString = Just $ Board.showMove mv
        mvBestString = Board.showMove mvBest
        eval = evalInt evalMove
        mate = evalMate evalMove

evalInt :: Stockfish.Evaluation -> Maybe Int 
evalInt (Right n) = Just n
evalInt (Left _) = Nothing

evalMate :: Stockfish.Evaluation -> Maybe Int 
evalMate (Right _) = Nothing
evalMate (Left n) = Just n

dbGameToPGN :: Game -> Maybe Pgn.Game
dbGameToPGN game = rightToMaybe $ Logic.gameFromStart Pgn.pgnToMove $ Pgn.unsafeMoves $ Te.pack $ gamePgn game
