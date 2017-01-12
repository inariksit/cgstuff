{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts #-}

module CG_SAT where

import Rule hiding ( Not, Negate )
import qualified Rule as R
import SAT ( Solver(..) )
import SAT.Named


import Data.Foldable ( fold )
import Data.IntMap ( IntMap, (!), elems )
import qualified Data.IntMap as IM
import Data.IntSet ( IntSet )
import qualified Data.IntSet as IS 
import Data.List ( intercalate, findIndices )
import Data.Map ( Map )
import qualified Data.Map as M
import Data.Maybe ( catMaybes )

import Control.Monad ( liftM2, mapAndUnzipM, zipWithM )
import Control.Monad.Trans
import Control.Monad.IO.Class ( MonadIO(..), liftIO )
import Control.Monad.State.Class
import Control.Monad.Reader.Class
import Control.Monad.Trans.State ( StateT(..) )
import Control.Monad.Trans.Reader ( ReaderT(..) )


--------------------------------------------------------------------------------

newtype CGMonad a = CGMonad (ReaderT Env (StateT Sentence IO) a)
  deriving (Functor, Applicative, Monad, MonadState Sentence, MonadReader Env, MonadIO)

{-  tagMap 
           ‾‾`v

         vblex |-> [321,         322,         323      ...]
                     |            |            |
                    vblex sg p1  vblex sg p2  vblex sg ...  
                ___,^
           rdMap 
-}
data Env = Env { tagMap :: Map Tag IntSet 
               , rdMap :: IntMap Reading 
               , allTags :: IntSet 
               , solver :: Solver } 
           --    deriving (Show,Eq)



type Sentence = IntMap Cohort
type Cohort = IntMap Lit

type SeqList a = [a] -- List of things that follow each other in sequence

data Pattern = Pat { positions :: OrList (SeqList Int)
                   , contexts :: SeqList Match } 
             | PatAlways 
             | Negate Pattern -- Negate goes beyond set negation and C
             deriving (Show,Eq,Ord)


data Match = Mix IntSet -- Cohort contains tags in IntSet and tags not in IntSet
           | Cau IntSet -- Cohort contains only tags in IntSet
           | Not IntSet -- Cohort contains no tags in IntSet
           | NotCau IntSet -- Cohort contains (not only) tags in IntSet:
                            -- either of Not and Mix are valid.
           | AllTags -- Cohort may contain any tag
           deriving (Show,Eq,Ord)


--------------------------------------------------------------------------------
-- Interaction with SAT-solver, non-pure functions

pattern2Lits :: Int -- ^ Position of the target cohort in the sentence
             -> Pattern -- ^ Conditions to turn into literals
             -> CGMonad (OrList Lit) -- ^ All possible ways to satisfy the conditions
pattern2Lits origin pat = do 
  s <- asks solver
  sentence <- get
  Or `fmap` sequence
        -- OBS. potential for sharing: if cohorts are e.g. [1,2],[1,3],[1,4],
        -- we can keep result of 1 somewhere and not compute it all over many times.
       [ do lits <- zipWithM makeCondLit cohorts matches :: CGMonad [Lit]            
            if length cohorts == length matches
              then liftIO $ andl' s lits
              else error "pattern2Lits: contextual test(s) out of scope"
          | inds <- getOrList $ positions pat  -- inds :: [Int]
          , let cohorts = catMaybes $ fmap (`IM.lookup` sentence) inds
          , let matches = contexts pat
       ] 

-- OBS. Try adding some short-term cache; add something in the state,
-- and before computing the literal, see if it's there
makeCondLit :: Cohort -> Match -> CGMonad Lit
makeCondLit coh mat = do 
  s <- asks solver
  liftIO $ case mat of
    Mix is -> do let (inmap,outmap) = partitionIM is coh
                 andl' s =<< sequence [ orl' s (elems inmap)
                                      , orl' s (elems outmap) ]

              -- Any difference whether to compute neg $ orl' or andl $ map neg?                 
    Cau is -> do let (inmap,outmap) = partitionIM is coh
                 andl' s =<< sequence [ orl' s (elems inmap)
                                      , neg `fmap` orl' s (elems outmap) ]

    Not is -> do let (inmap,outmap) = partitionIM is coh
                 andl' s =<< sequence [ neg `fmap` orl' s (elems inmap)
                                      , orl' s (elems outmap) ]

  -- `NOT 1C foo' means: "either there's no foo, or the foo is not unique."
  -- Either way, having at least one true non-foo lit fulfils the condition,
  -- because the cohort may not be empty.
    NotCau is -> do let (_,outmap) = partitionIM is coh
                    orl' s (elems outmap) 

    AllTags   -> return true

 where
  partitionIM :: IntSet -> IntMap Lit -> (IntMap Lit,IntMap Lit)
  partitionIM is im = let onlykeys = IM.fromSet (const true) is --Intersection is based on keys
                          inmap = IM.intersection im onlykeys 
                          outmap = IM.difference im onlykeys
                      in (inmap,outmap)



--------------------------------------------------------------------------------

ctx2Pattern :: Int  -- ^ Sentence length
            -> Int  -- ^ Absolute position of the target in the sentence
            -> Context -- ^ Context to be transformed
            -> CGMonad (OrList Pattern) -- ^ List of patterns. Length >1 only if the context is template.
ctx2Pattern senlen origin ctx = case ctx of
  Always -> return (Or [PatAlways])
  c@(Ctx posn polr tgst)
    -> do (ps,m) <- singleCtx2Pat c
          return (Or [Pat ps m])
          
  Link ctxs 
    -> do (ps,cs) <- mapAndUnzipM singleCtx2Pat (getAndList ctxs)
          return (Or [Pat (fold ps) (fold cs)])
    -- To support linked templates (which don't make sense), do like below. 
    -- pats <- And `fmap` (ctx2Pattern senlen origin `mapM` getAndList ctxs) 
    -- :t pats :: AndList (OrList Pattern)

  Template ctxs
    -> do pats <- ctx2Pattern senlen origin `mapM` ctxs --  :: OrList Pattern
          return (fold pats)

  R.Negate ctx 
    -> do pat <- ctx2Pattern senlen origin ctx -- :: OrList Pattern
          return (fmap Negate pat)

 where 
  singleCtx2Pat (Ctx posn polr tgst) = 
    do tagset <- normaliseAbs tgst `fmap` asks tagMap
       let allPositions = pos2inds posn senlen origin
       let match = maybe AllTags (getMatch posn polr) tagset
       return (fmap (:[]) allPositions, [match] ) 

pos2inds :: Position -> Int -> Int -> OrList Int
pos2inds posn senlen origin = case scan posn of 
  Exactly -> Or [origin + relInd]
  _       -> Or absInds
 where
  relInd = R.pos posn
  absInds = if relInd<0 then [1 .. origin+relInd]
                else [origin+relInd .. senlen]

getMatch :: Position -> Polarity -> (IntSet -> Match)
getMatch (Pos _ NC _) Yes   = Mix
getMatch (Pos _ NC _) R.Not = Not
getMatch (Pos _ C _)  Yes   = Cau
getMatch (Pos _ C _)  R.Not = NotCau


--------------------------------------------------------------------------------
-- From here on, only pure helper functions


{- rdMap --  1 |-> vblex sg p3
             2 |-> noun sg mf
               ...
          9023 |-> "aurrera" adv -}
mkRdMap :: [Reading] -> IntMap Reading
mkRdMap = IM.fromDistinctAscList . zip [1..]

{- tagMap    --  vblex |-> IS(1,30,31,32,..,490)
                 sg    |-> IS(1,2,3,120,1800)
                 mf    |-> IS(2,20,210)
                 adv   |-> IS() -}
mkTagMap :: [Tag] -> [Reading] -> Map Tag IntSet 
mkTagMap ts rds = M.fromList $
  ts `for` \t -> let getInds = IS.fromList . map (1+) . findIndices (elem t)
                 in (t, getInds rdLists) 
 where 
  for = flip fmap 
  rdLists = map getAndList rds
  -- maybe write this more readably later? --getInds :: Tag -> [Reading] -> IntSet

--------------------------------------------------------------------------------

-- | Takes a tagset, with OrLists of underspecified readings,  and returns corresponding IntSets of fully specified readings.
-- Compare to normaliseRel in cghs/Rule: it only does the set operations relative to the underspecified readings, not with absolute IntSets.
-- That's why we cannot handle Diffs in normaliseRel, but only here.
normaliseAbs :: TagSet -> Map Tag IntSet -> Maybe IntSet
normaliseAbs tagset tagmap = case tagset of
  All -> Nothing
  Set s -> Just (lu s tagmap)
  Union t t' -> liftM2 IS.union (norm t) (norm t')
  Inters t t' -> liftM2 IS.intersection (norm t) (norm t')

{- Intended behaviour:
     adv adV (ada "very") `diff` ada == adv adV
     adv adV ada `diff` (ada "very") == adv adV (ada ((*) -"very")) -}
  Diff t t' -> liftM2 IS.difference (norm t) (norm t')

{- say t=[n,adj] and t'=[m,f,mf]
   is  = specified readings that match t: (n foo), (n bar), (n mf), ... , (adj foo), (adj bar), (adj f), ..
   is' = specified readings that match t': (n m), (n f), (vblex sg p3 mf), (adj f), ..
   intersection of the specified readings returns those that match 
   sequence [[n,adj],[m,f,mf]]: (n m), (n f), ..., (adj f), (adj mf) -}
  Cart t t' -> liftM2 IS.intersection (norm t) (norm t')

 where
  norm = (`normaliseAbs` tagmap)

  lu :: OrList Reading -> M.Map Tag IntSet -> IntSet
  lu s m = IS.unions [ foldl1 IS.intersection $ 
                        catMaybes [ M.lookup t m | t <- getAndList ts ]
                        | ts <- getOrList s ]
