{-# LANGUAGE LambdaCase, RecordWildCards, TemplateHaskell, PatternSynonyms #-}
module Pipeline where

import Prelude
import Control.Monad
import Data.Maybe (maybe, fromJust, fromMaybe)
import Text.Printf
import Text.Pretty.Simple (pPrint)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>))
import qualified Text.Show.Pretty as PP

import Check hiding (check)
import Eval
import Grin
import TypeEnv
import TypeCheck
import Optimizations
import qualified Statistics
import Pretty()
import Transformations.CountVariableUse
import Transformations.AssignStoreIDs
import Transformations.GenerateEval
import qualified Transformations.Simplifying.Vectorisation2 as Vectorisation2
import Transformations.Simplifying.Vectorisation
import Transformations.BindNormalisation
import qualified Lint
import PrettyLint
import Transformations.Simplifying.SplitFetch
import Transformations.Simplifying.CaseSimplification
import Transformations.Simplifying.RightHoistFetch
import Transformations.Optimising.Inlining (inlineEval, inlineApply, inlineBuiltins)
import Transformations.UnitPropagation
import Transformations.MangleNames
import Transformations.EffectMap
import qualified Transformations.Simplifying.RightHoistFetch2 as RHF
import Transformations.Simplifying.RegisterIntroduction
import Transformations.Playground
import AbstractInterpretation.AbstractRunGrin
import AbstractInterpretation.HPTResult
import qualified AbstractInterpretation.HPTResultNew as HPT
import AbstractInterpretation.PrettyHPT
import qualified AbstractInterpretation.Pretty as HPT
import qualified AbstractInterpretation.IR as HPT
import qualified AbstractInterpretation.CodeGen as HPT
import qualified AbstractInterpretation.Reduce as HPT
import qualified Reducer.LLVM.CodeGen as CGLLVM
import qualified Reducer.LLVM.JIT as JITLLVM
import System.Directory
import System.Process
import Data.Bifunctor

import qualified Data.Bimap as Bimap
import Data.Map as Map
import LLVM.Pretty (ppllvm)
import qualified Data.Text.Lazy.IO as Text

import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict
import Control.Monad.IO.Class
import Lens.Micro.TH
import Lens.Micro.Mtl
import Data.Set
import System.FilePath
import System.Exit
import Control.DeepSeq
import Debug.Trace
import Lens.Micro
import Data.List

import Lint

import Test.QuickCheck
import Test.QuickCheck.Monadic
import Data.Algorithm.Diff
import Data.Algorithm.DiffOutput
import Control.Monad.Extra

type RenameVariablesMap = Map String String

data Transformation
  -- Simplifying
  = RegisterIntroduction
  | Vectorisation
  | SplitFetch
  | CaseSimplification
  | RightHoistFetch
  | InlineEval
  | InlineApply
  | InlineBuiltins
  -- Misc
  | GenerateEval
  | BindNormalisation
  | ConstantFolding
  | UnitPropagation
  | MangleNames
  -- Optimizations
  | EvaluatedCaseElimination
  | TrivialCaseElimination
  | SparseCaseOptimisation
  | UpdateElimination
  | CopyPropagation
  | ConstantPropagation
  | DeadProcedureElimination
  | DeadParameterElimination
  | DeadVariableElimination
  | CommonSubExpressionElimination
  | CaseCopyPropagation
  | CaseHoisting
  | GeneralizedUnboxing
  | ArityRaising
  | LateInlining
  deriving (Enum, Eq, Ord, Show)

noTypeEnv :: (Exp -> Exp) -> (TypeEnv, Exp) -> (TypeEnv, Exp)
noTypeEnv f (t, e) = (t, f e)

noEffectMap :: ((TypeEnv, Exp) -> (TypeEnv, Exp)) -> (TypeEnv, EffectMap, Exp) -> (TypeEnv, EffectMap, Exp)
noEffectMap f (te0, em0, e0) = let (te1, e1) = f (te0, e0) in (te1, em0, e1)

transformation :: Int -> Transformation -> (TypeEnv, EffectMap, Exp) -> (TypeEnv, EffectMap, Exp)
transformation n = \case
  Vectorisation                   -> noEffectMap Vectorisation2.vectorisation
  GenerateEval                    -> noEffectMap $ noTypeEnv generateEval
  CaseSimplification              -> noEffectMap $ noTypeEnv caseSimplification
  SplitFetch                      -> noEffectMap $ noTypeEnv splitFetch
  RegisterIntroduction            -> noEffectMap $ noTypeEnv $ registerIntroductionI n
  RightHoistFetch                 -> noEffectMap $ noTypeEnv RHF.rightHoistFetch
  -- misc
  MangleNames                     -> noEffectMap $ noTypeEnv mangleNames
  -- optimising
  BindNormalisation               -> noEffectMap $ noTypeEnv bindNormalisation
  ConstantFolding                 -> noEffectMap $ noTypeEnv constantFolding
  EvaluatedCaseElimination        -> noEffectMap $ noTypeEnv evaluatedCaseElimination
  TrivialCaseElimination          -> noEffectMap $ noTypeEnv trivialCaseElimination
  UpdateElimination               -> noEffectMap $ noTypeEnv updateElimination
  CopyPropagation                 -> noEffectMap $ noTypeEnv copyPropagation
  ConstantPropagation             -> noEffectMap $ noTypeEnv constantPropagation
  DeadProcedureElimination        -> noEffectMap $ noTypeEnv deadProcedureElimination
  DeadParameterElimination        -> noEffectMap $ noTypeEnv deadParameterElimination
  InlineEval                      -> noEffectMap inlineEval
  InlineApply                     -> noEffectMap inlineApply
  InlineBuiltins                  -> noEffectMap inlineBuiltins
  SparseCaseOptimisation          -> noEffectMap sparseCaseOptimisation
  DeadVariableElimination         -> deadVariableElimination
  CommonSubExpressionElimination  -> noEffectMap commonSubExpressionElimination
  CaseCopyPropagation             -> noEffectMap caseCopyPropagation
  CaseHoisting                    -> noEffectMap caseHoisting
  GeneralizedUnboxing             -> noEffectMap generalizedUnboxing
  ArityRaising                    -> noEffectMap arityRaising
  LateInlining                    -> noEffectMap lateInlining
  UnitPropagation                 -> noEffectMap unitPropagation

-- TODO
precondition :: Transformation -> [Check]
precondition _ = []

postcondition :: Transformation -> [Check]
postcondition _ = []

newtype Hidden a = H a

instance Show (Hidden a) where
  show _ = "(hidden)"

instance Eq (Hidden a) where
  _ == _ = True

data HPTStep
  = CompileHPT
  | PrintHPTCode
  | RunHPTPure
  | PrintHPTResult
  deriving (Eq, Show)

data EffectStep
  = CalcEffectMap
  | PrintEffectMap
  deriving (Eq, Show)

data PipelineStep
  = HPT HPTStep
  | Eff EffectStep
  | T Transformation
  | Pass [PipelineStep]
  | PrintGrinH (Hidden (Doc -> Doc))
  | PureEval
  | JITLLVM
  | PrintAST
  | SaveLLVM FilePath
  | SaveGrin FilePath
  | DebugTransformationH (Hidden (Exp -> Exp))
  | Statistics
  | PrintTypeEnv
  | Lint
  | ConfluenceTest Int
  deriving (Eq, Show)

pattern PrintGrin :: (Doc -> Doc) -> PipelineStep
pattern PrintGrin c <- PrintGrinH (H c)
  where PrintGrin c =  PrintGrinH (H c)

pattern DebugTransformation :: (Exp -> Exp) -> PipelineStep
pattern DebugTransformation t <- DebugTransformationH (H t)
  where DebugTransformation t =  DebugTransformationH (H t)

data PipelineOpts = PipelineOpts
  { _poOutputDir  :: FilePath
  , _poFailOnLint :: Bool
  }

defaultOpts :: PipelineOpts
defaultOpts = PipelineOpts
  { _poOutputDir  = "./"
  , _poFailOnLint = True
  }

type PipelineM a = ReaderT PipelineOpts (StateT PState IO) a
data PState = PState
    { _psExp        :: Exp
    , _psTransStep  :: Int
    , _psSaveIdx    :: Int
    , _psHPTProgram :: Maybe HPT.HPTProgram
    , _psHPTResult  :: Maybe HPT.HPTResult
    , _psTypeEnv    :: Maybe TypeEnv
    , _psEffectMap  :: Maybe EffectMap
    , _psErrors     :: [String]
    }

makeLenses ''PState
makeLenses ''PipelineOpts

data PipelineEff
  = None
  | ExpChanged
  deriving (Eq, Show)

_None :: Traversal' PipelineEff ()
_None f None = const None <$> f ()
_None _ rest = pure rest

_ExpChanged :: Traversal' PipelineEff ()
_ExpChanged f ExpChanged = const ExpChanged <$> f ()
_ExpChanged _ rest       = pure rest

pipelineStep :: PipelineStep -> PipelineM PipelineEff
pipelineStep p = do
  case p of
    T{}     -> pure ()
    Pass{}  -> pure () -- each pass step will be printed anyway
    _       -> liftIO $ putStrLn $ printf "PipelineStep: %-35s" (show p)
  before <- use psExp
  case p of
    HPT hptStep -> case hptStep of
      CompileHPT      -> compileHPT
      PrintHPTCode    -> printHPTCode
      RunHPTPure      -> runHPTPure
      PrintHPTResult  -> printHPTResult
    Eff eff -> case eff of
      CalcEffectMap   -> calcEffectMap
      PrintEffectMap  -> printEffectMap
    T t             -> transformationM t
    Pass pass       -> mapM_ pipelineStep pass
    PrintGrin d     -> printGrinM d
    PureEval        -> pureEval
    JITLLVM         -> jitLLVM
    SaveLLVM path   -> saveLLVM path
    SaveGrin path   -> saveGrin path
    PrintAST        -> printAST
    PrintTypeEnv    -> printTypeEnv
    DebugTransformation t -> debugTransformation t
    Statistics      -> statistics
    Lint            -> lintGrin Nothing
    ConfluenceTest n -> void $ loopM confluenceTest n
  after <- use psExp
  let eff = if before == after then None else ExpChanged
  case p of
    T{} -> liftIO $ putStrLn $ printf "PipelineStep: %-35s has effect: %s" (show p) (show eff)
    _   -> pure ()
  -- TODO: Test this only for development mode.
  return eff

calcEffectMap :: PipelineM ()
calcEffectMap = do
  grin <- use psExp
  env0 <- fromMaybe (traceShow "emptyTypEnv is used" emptyTypeEnv) <$> use psTypeEnv
  psEffectMap .= Just (effectMap (env0, grin))

printEffectMap :: PipelineM ()
printEffectMap = do
  grin <- use psExp
  env0 <- fromMaybe (traceShow "emptyTypEnv is used" emptyTypeEnv) <$> use psTypeEnv
  liftIO $ print $ pretty env0

compileHPT :: PipelineM ()
compileHPT = do
  grin <- use psExp
  case HPT.codeGen grin of
    Right hptProgram -> do
      psHPTProgram .= Just hptProgram
    Left e -> do
      psErrors %= (e:)
      psHPTProgram .= Nothing
  {-
  let nonlinearSet  = nonlinearVariables grin
      countMap      = countVariableUse grin
  --pPrint countMap
  --pPrint nonlinearSet
  liftIO $ putStrLn "non-linear variables:"
  liftIO $ print . pretty $ nonlinearSet
  -}

printHPTCode :: PipelineM ()
printHPTCode = do
  hptProgram <- use psHPTProgram
  let printHPT a = do
        print . HPT.prettyInstructions (Just a) . HPT.hptInstructions $ a
        putStrLn $ printf "memory size    %d" $ HPT.hptMemoryCounter a
        putStrLn $ printf "register count %d" $ HPT.hptRegisterCounter a
        putStrLn $ printf "variable count %d" $ Map.size $ HPT.hptRegisterMap a
  maybe (pure ()) (liftIO . printHPT) hptProgram

printHPTResult :: PipelineM ()
printHPTResult = use psHPTResult >>= \case
  Nothing -> pure ()
  Just result -> liftIO $ print . pretty $ result

runHPTPure :: PipelineM ()
runHPTPure = use psHPTProgram >>= \case
  Nothing -> psHPTResult .= Nothing
  Just hptProgram -> do
    let hptResult = HPT.evalHPT hptProgram
        result = HPT.toHPTResult hptProgram hptResult
    psHPTResult .= Just result
    case typeEnvFromHPTResult result of
      Right te  -> psTypeEnv .= Just te
      Left err  -> do
        psErrors %= (err :)
        psTypeEnv .= Nothing

printTypeEnv :: PipelineM ()
printTypeEnv = do
  Just typeEnv <- use psTypeEnv
  liftIO $ print . pretty $ typeEnv

preconditionCheck :: Transformation -> PipelineM ()
preconditionCheck t = do
  exp <- use psExp
  forM_ (checks Nothing (precondition t) exp) $ \case
    (c, r) -> liftIO . putStrLn $ unwords ["The", show c, "precondition of", show t, ": ", show r]

postconditionCheck :: Transformation -> PipelineM ()
postconditionCheck t = do
  exp <- use psExp
  forM_ (checks Nothing (postcondition t) exp) $ \case
    (c, r) -> liftIO . putStrLn $ unwords ["The", show c, "postcondition of", show t, ": ", show r]

transformationM :: Transformation -> PipelineM ()
transformationM t = do
  preconditionCheck t
  env0 <- fromMaybe (traceShow "emptyTypEnv is used" emptyTypeEnv) <$> use psTypeEnv
  effs0 <- fromMaybe (traceShow "emptyEffectMap is used" mempty) <$> use psEffectMap
  n    <- use psTransStep
  exp0 <- use psExp
  let (env1, effs1, exp1) = transformation n t (env0, effs0, exp0)
  psTypeEnv .= Just env1
  psExp     .= exp1
  psTransStep %= (+1)
  postconditionCheck t

pureEval :: PipelineM ()
pureEval = do
  e <- use psExp
  liftIO (print =<< pretty <$> evalProgram PureReducer e)

printGrinM :: (Doc -> Doc) -> PipelineM ()
printGrinM color = do
  e <- use psExp
  liftIO . print . color $ pretty e

jitLLVM :: PipelineM ()
jitLLVM = do
  e <- use psExp
  Just typeEnv <- use psTypeEnv
  liftIO $ do
    val <- JITLLVM.eagerJit (CGLLVM.codeGen typeEnv e) "grinMain"
    print $ pretty val

printAST :: PipelineM ()
printAST = do
  e <- use psExp
  pPrint e

saveGrin :: FilePath -> PipelineM ()
saveGrin fn = do
  psSaveIdx %= succ
  n <- use psSaveIdx
  e <- use psExp
  outputDir <- view poOutputDir
  let fname = printf "%03d.%s" n fn
  let content = show $ plain $ pretty e
  liftIO $ do
    createDirectoryIfMissing True outputDir
    writeFile (outputDir </> fname) content

saveLLVM :: FilePath -> PipelineM ()
saveLLVM fname' = do
  e <- use psExp
  psSaveIdx %= succ
  n <- use psSaveIdx
  Just typeEnv <- use psTypeEnv
  o <- view poOutputDir
  let fname = o </> printf "%03d.%s" n fname'
      code = CGLLVM.codeGen typeEnv e
      llName = printf "%s.ll" fname
      sName = printf "%s.s" fname
  liftIO . void $ do
    Text.putStrLn $ ppllvm code
    putStrLn "* to LLVM *"
    _ <- CGLLVM.toLLVM llName code
    putStrLn "* LLVM X64 codegen *"
    callCommand $ printf "opt-5.0 -O3 %s | llc-5.0 -o %s" llName sName
    readFile sName >>= putStrLn

debugTransformation :: (Exp -> Exp) -> PipelineM ()
debugTransformation t = do
  e <- use psExp
  liftIO . print $ pretty (t e)

statistics :: PipelineM ()
statistics = do
  e <- use psExp
  liftIO . print $ Statistics.statistics e

lintGrin :: Maybe String -> PipelineM ()
lintGrin mPhaseName = do
  pipelineStep $ HPT CompileHPT
  pipelineStep $ HPT RunHPTPure
  exp <- use psExp
  mTypeEnv <- use psTypeEnv
  let lintExp@(_, errorMap) = Lint.lint mTypeEnv exp
  when (Map.size errorMap > 0) $ do
    psErrors %= ((concat $ Map.elems errorMap) ++)

  -- print errors
  errors <- use psErrors
  unless (Prelude.null errors) $ void $ do
    failOnLintError <- view poFailOnLint
    when failOnLintError $ void $ do
      liftIO . print $ prettyLintExp lintExp
      pipelineStep $ HPT PrintHPTResult
    case mPhaseName of
      Just phaseName  -> liftIO . putStrLn $ printf "error after %s:\n%s" phaseName (unlines errors)
      Nothing         -> liftIO . putStrLn $ printf "error:\n%s" (unlines errors)

    failOnLintError <- view poFailOnLint
    when failOnLintError $ do
      liftIO $ die "illegal code"

transformationWhitelist =
  -- Misc
  [ UnitPropagation
  -- Optimizations
  , EvaluatedCaseElimination
  , TrivialCaseElimination
  , SparseCaseOptimisation
  , UpdateElimination
  , CopyPropagation
  , ConstantPropagation
  , DeadProcedureElimination
  , DeadParameterElimination
  , DeadVariableElimination
  , CommonSubExpressionElimination
  , CaseCopyPropagation
  , CaseHoisting
  , GeneralizedUnboxing
  , ArityRaising
  , LateInlining
  ]

randomTransform :: Exp -> IO (Exp, [Transformation])
randomTransform exp = do
    permutation <- generate $ shuffle transformationWhitelist
    (_, transformed) <- pipeline defaultOpts exp $ makePipeline permutation
    return (transformed, permutation)
  where makePipeline = (extraPass :) . (>>= (: [extraPass])) . fmap T
        extraPass = Pass [T BindNormalisation, Lint, HPT CompileHPT, HPT RunHPTPure]

confluenceTest :: Int -> PipelineM (Either Int ())
confluenceTest iter = use psExp >>= \exp -> liftIO $ if iter <= 0 then (return $ Right ()) else do
  (exps@(e1:e2:_), (t1:t2:_)) <- unzip <$> replicateM 2 (randomTransform exp)
  if (mangleNames e1 == mangleNames e2) then (return $ Left (iter - 1)) else do
    let (lines1:lines2:_) = (lines . show . plain . pretty) <$> exps
    putStrLn $ "\nDiff between transformed codes:"
    putStrLn $ ppDiff $ getGroupedDiff lines1 lines2
    putStrLn "First tranformation permutation:"
    putStrLn $ show t1
    putStrLn "\nSecond transformation permutation:"
    putStrLn $ show t2
    return $ Right ()

check :: PipelineM ()
check = do
  e <- use psExp
  let nonUnique = nonUniqueNames e
  liftIO $ putStrLn $ unwords ["Non unique names:", show nonUnique]
  let nonDefined = nonDefinedNames e
  liftIO . putStrLn $ unwords ["Non defined names:", show nonDefined]


-- | Runs the pipeline and returns the last version of the given
-- expression.
pipeline :: PipelineOpts -> Exp -> [PipelineStep] -> IO ([(PipelineStep, PipelineEff)], Exp)
pipeline o e ps = do
  print ps
  fmap (second _psExp) .
    flip runStateT start .
    flip runReaderT o $
    mapM (\p -> (,) p <$> pipelineStep p) ps
  where
    start = PState
      { _psExp        = e
      , _psTransStep  = 0
      , _psSaveIdx    = 0
      , _psHPTProgram = Nothing
      , _psHPTResult  = Nothing
      , _psTypeEnv    = Nothing
      , _psEffectMap  = Nothing
      , _psErrors     = []
      }

-- | Run the pipeline with the given set of transformations, till
-- it reaches a fixpoint where none of the pipeline transformations
-- changes the expression itself, the order of the transformations
-- are defined in the pipeline list. After all round the TypeEnv
-- is restored
optimizeWithPM :: PipelineOpts -> Exp -> [PipelineStep] -> PipelineM ()
optimizeWithPM o e ps = loop where
  loop = do
    -- Run every step and on changes run HPT
    effs <- forM ps $ \p -> do
      eff <- pipelineStep p
      when (eff == ExpChanged) $ void $ do
        pipelineStep $ SaveGrin (fmap (\case ' ' -> '-' ; c -> c) $ show p)
        lintGrin . Just $ show p
        pipelineStep $ Eff CalcEffectMap
      pure eff
    -- Run loop again on change
    when (any (match _ExpChanged) effs)
      loop

optimize :: PipelineOpts -> Exp -> [PipelineStep] -> [PipelineStep] -> IO Exp
optimize o e pre post = optimizeWith o e pre optimizations post where
  optimizations =
    [ BindNormalisation
    , EvaluatedCaseElimination
    , TrivialCaseElimination
    , SparseCaseOptimisation
    , UpdateElimination
    , CopyPropagation
    , ConstantPropagation
    , DeadProcedureElimination
    , DeadVariableElimination
    , DeadParameterElimination
    , CommonSubExpressionElimination
    , CaseCopyPropagation
    , CaseHoisting
    , GeneralizedUnboxing
    , ArityRaising
    , InlineEval
    , InlineApply
    , LateInlining
    ]

optimizeWith :: PipelineOpts -> Exp -> [PipelineStep] -> [Transformation] -> [PipelineStep] -> IO Exp
optimizeWith o e pre optimizations post = fmap fst $ flip runStateT start $ flip runReaderT o $ do
  lintGrin $ Just "init"

  mapM_ pipelineStep pre

  mapM_ pipelineStep
    [ HPT CompileHPT
    , HPT RunHPTPure
    , T UnitPropagation
    , Eff CalcEffectMap
    ]
  optimizeWithPM o e $ fmap T optimizations
  mapM_ pipelineStep post

  use psExp
  where
    start = PState
      { _psExp        = e
      , _psTransStep  = 0
      , _psSaveIdx    = 0
      , _psHPTProgram = Nothing
      , _psHPTResult  = Nothing
      , _psTypeEnv    = Nothing
      , _psEffectMap  = Nothing
      , _psErrors     = []
      }
