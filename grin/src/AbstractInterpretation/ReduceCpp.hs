{-# LANGUAGE LambdaCase, RecordWildCards, Strict #-}
module AbstractInterpretation.ReduceCpp where

import qualified Data.ByteString.Lazy as LBS
import qualified System.Process
import System.IO.Unsafe

import AbstractInterpretation.IR
import AbstractInterpretation.Reduce (AbstractInterpretationResult)
import AbstractInterpretation.BinaryResult
import AbstractInterpretation.BinaryIR

evalAbstractProgramCpp :: AbstractProgram -> IO AbstractInterpretationResult
evalAbstractProgramCpp prg = do
  -- save abstract program to temp file
  LBS.writeFile "dataflow_program.dfbin" $ encodeAbstractProgram prg

  -- run external reducer
  System.Process.callCommand "df_test dataflow_program.dfbin"

  -- read back result
  loadAbstractInterpretationResult "dataflow_program.dfbin.dat"

evalAbstractProgramCppUnsafe :: AbstractProgram -> AbstractInterpretationResult
evalAbstractProgramCppUnsafe a = unsafePerformIO $ evalAbstractProgramCpp a
