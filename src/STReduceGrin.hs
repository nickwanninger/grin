{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Strict #-}
module STReduceGrin (reduceFun) where

import Debug.Trace

import Data.Map (Map)
import qualified Data.Map as Map
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Control.Monad.State
import Control.Monad.Reader

import Data.Vector.Mutable as Vector
import Data.STRef.Strict
import Control.Monad.ST

import Grin

-- models computer memory
data SStore s = SStore {
    sVector :: STRef s (STVector s Val)
  , sLast   :: STRef s Int
  }

emptyStore1 :: ST s (SStore s)
emptyStore1 = SStore <$> (new 1024 >>= newSTRef) <*> newSTRef 0

-- models cpu registers
type Env = Map Name Val
type GrinS s a = ReaderT (Prog, SStore s) (ST s) a

getProg :: GrinS s Prog
getProg = reader fst

getStore :: GrinS s (SStore s)
getStore = reader snd

getLength :: SStore s -> GrinS s Int
getLength (SStore sr _) = Vector.length <$> lift (readSTRef sr)

-- TODO: Resize
insertStore :: Val -> GrinS s ()
insertStore x = do
  (SStore vr l) <- getStore
  lift $ do
    n <- readSTRef l
    v <- readSTRef vr
    Vector.write v n x
    writeSTRef l (n + 1)

lookupStore :: Int -> GrinS s Val
lookupStore n = do
  (SStore vr _) <- getStore
  lift $ do
    v <- readSTRef vr
    Vector.read v n

updateStore :: Int -> Val -> GrinS s ()
updateStore n x = do
  (SStore vr _) <- getStore
  lift $ do
    v <- readSTRef vr
    Vector.write v n x

bindPatMany :: Env -> [Val] -> [LPat] -> Env
bindPatMany a [] [] = a
bindPatMany a (x:xs) (y:ys) = bindPatMany (bindPat a x y) xs ys
bindPatMany _ x y = error $ "bindPatMany - pattern mismatch: " ++ show (x,y)

bindPat :: Env -> Val -> LPat -> Env
bindPat env v p = case p of
  Var n -> case v of
              ValTag{}  -> Map.insert n v env
              Unit      -> Map.insert n v env
              Lit{}     -> Map.insert n v env
              Loc{}     -> Map.insert n v env
              Undefined -> Map.insert n v env
              _ -> {-trace ("bindPat - illegal value: " ++ show v) $ -}Map.insert n v env -- WTF????
              _ -> error $ "bindPat - illegal value: " ++ show v
  ConstTagNode t l -> case v of
                  ConstTagNode vt vl | vt == t -> bindPatMany env vl l
                  _ -> error $ "bindPat - illegal value for ConstTagNode: " ++ show v
  VarTagNode n l -> case v of
                  ConstTagNode vt vl -> bindPatMany (Map.insert n (ValTag vt) env) vl l
                  _ -> error $ "bindPat - illegal value for ConstTagNode: " ++ show v
  _ | p == v -> env
    | otherwise -> error $ "bindPat - pattern mismatch" ++ show (v,p)

lookupEnv :: Name -> Env -> Val
lookupEnv n env = Map.findWithDefault (error $ "missing variable: " ++ n) n env

evalVal :: Env -> Val -> Val
evalVal env = \case
  v@Lit{}     -> v
  Var n       -> lookupEnv n env
  ConstTagNode t a -> ConstTagNode t $ map (evalVal env) a
  VarTagNode n a -> case lookupEnv n env of
                  Var n     -> VarTagNode n $ map (evalVal env) a
                  ValTag t  -> ConstTagNode t $ map (evalVal env) a
                  x -> error $ "evalVal - invalid VarTagNode tag: " ++ show x
  v@ValTag{}  -> v
  v@Unit      -> v
  v@Loc{}     -> v
  x -> error $ "evalVal: " ++ show x

evalExp :: Env -> Exp -> GrinS s Val
evalExp env = \case
  Bind op pat exp -> evalSimpleExp env op >>= \v -> evalExp (bindPat env v pat) exp
  Case v alts -> case evalVal env v of
    ConstTagNode t l ->
                   let (vars,exp) = head $ [(b,exp) | Alt (NodePat a b) exp <- alts, a == t] ++ error ("evalExp - missing Case Node alternative for: " ++ show t)
                       go a [] [] = a
                       go a (x:xs) (y:ys) = go (Map.insert x y a) xs ys
                       go _ x y = error $ "invalid pattern and constructor: " ++ show (t,x,y)
                   in  evalExp (go env vars l) exp
    ValTag t    -> evalExp env $ head $ [exp | Alt (TagPat a) exp <- alts, a == t] ++ error ("evalExp - missing Case Tag alternative for: " ++ show t)
    Lit l       -> evalExp env $ head $ [exp | Alt (LitPat a) exp <- alts, a == l] ++ error ("evalExp - missing Case Lit alternative for: " ++ show l)
    x -> error $ "evalExp - invalid Case dispatch value: " ++ show x
  SExp exp -> evalSimpleExp env exp
  x -> error $ "evalExp: " ++ show x

evalSimpleExp :: Env -> SimpleExp -> GrinS s Val
evalSimpleExp env = \case
  App n a -> do
              let args = map (evalVal env) a
                  go a [] [] = a
                  go a (x:xs) (y:ys) = go (Map.insert x y a) xs ys
                  go _ x y = error $ "invalid pattern for function: " ++ show (n,x,y)
              case n of
                "add" -> primAdd args
                "mul" -> primMul args
                "intPrint" -> primIntPrint args
                "intGT" -> primIntGT args
                "intAdd" -> primAdd args
                _ -> do
                  Def _ vars body <- (Map.findWithDefault (error $ "unknown function: " ++ n) n) <$> getProg
                  evalExp (go env vars args) body
  Return v -> return $ evalVal env v
  Store v -> do
              l <- getLength =<< getStore
              let v' = evalVal env v
              insertStore v'  
              -- modify' (\(StoreMap m s) -> StoreMap (IntMap.insert l v' m) (s+1))
              return $ Loc l
  Fetch n -> case lookupEnv n env of
              Loc l -> lookupStore l
              x -> error $ "evalSimpleExp - Fetch expected location, got: " ++ show x
--  | FetchI  Name Int -- fetch node component
  Update n v -> do
              let v' = evalVal env v
              case lookupEnv n env of
                Loc l -> updateStore l v' >> return v'
                x -> error $ "evalSimpleExp - Update expected location, got: " ++ show x
  Block a -> evalExp env a
  x -> error $ "evalSimpleExp: " ++ show x

-- primitive functions
primIntGT [Lit (LFloat a), Lit (LFloat b)] = return $ ValTag $ Tag C (if a > b then "True" else "False") 0
primIntGT x = error $ "primIntGT - invalid arguments: " ++ show x

primIntPrint [Lit (LFloat a)] = return $ Lit $ LFloat $ a
primIntPrint x = error $ "primIntPrint - invalid arguments: " ++ show x

primAdd [Lit (LFloat a), Lit (LFloat b)] = return $ Lit $ LFloat $ a + b
primAdd x = error $ "primAdd - invalid arguments: " ++ show x

primMul [Lit (LFloat a), Lit (LFloat b)] = return $ Lit $ LFloat $ a * b
primMul x = error $ "primMul - invalid arguments: " ++ show x

reduce :: Exp -> Val
reduce e = runST $ do
  store <- emptyStore1
  runReaderT (evalExp mempty e) (mempty, store)

reduceFun :: [Def] -> Name -> Val
reduceFun l n = runST $ do
  store <- emptyStore1
  runReaderT (evalExp mempty e) (m, store)
  where
    m = Map.fromList [(n,d) | d@(Def n _ _) <- l]
    e = case Map.lookup n m of
          Nothing -> error $ "missing function: " ++ n
          Just (Def _ [] a) -> a
          _ -> error $ "function " ++ n ++ " has arguments"

sadd = App "add" [Lit $ LFloat 3, Lit $ LFloat 2]
test = SExp sadd
test2 = Bind sadd (Var "a") $ SExp $ App "mul" [Var "a", Var "a"]
