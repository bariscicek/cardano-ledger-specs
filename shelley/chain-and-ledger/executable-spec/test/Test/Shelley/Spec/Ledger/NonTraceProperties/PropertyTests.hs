{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Test.Shelley.Spec.Ledger.NonTraceProperties.PropertyTests (nonTracePropertyTests) where

import Cardano.Crypto.Hash (ShortHash)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.MultiSet (filter, fromSet, occur, size, unions)
import Data.Proxy
import qualified Data.Set as Set
import Hedgehog
  ( Property,
    classify,
    failure,
    label,
    property,
    success,
    withTests,
    (/==),
    (===),
  )
import qualified Hedgehog
import qualified Hedgehog.Gen as Gen
import Hedgehog.Internal.Property (LabelName (..))
import Shelley.Spec.Ledger.Coin
import Shelley.Spec.Ledger.Core ((<|))
import Shelley.Spec.Ledger.LedgerState
import Shelley.Spec.Ledger.PParams
import Shelley.Spec.Ledger.Slot
import Shelley.Spec.Ledger.Tx
  ( addrWits,
    _body,
    _certs,
    _inputs,
    _outputs,
    _witnessSet,
    _forge,
    pattern TxIn,
    pattern TxOut,
    pattern UTxOOut,
  )
import Shelley.Spec.Ledger.UTxO
  ( balance,
    hashTxBody,
    makeWitnessVKey,
    totalDeposits,
    txid,
    txins,
    txouts,
    verifyWitVKey,
  )
import Shelley.Spec.Ledger.Value
  ( getAdaAmount,
  compactValueToValue,
  zeroV,
  lt,
  coinToValue,
  eq, )
import Test.Shelley.Spec.Ledger.ConcreteCryptoTypes
import Test.Shelley.Spec.Ledger.NonTraceProperties.Generator
import Test.Shelley.Spec.Ledger.NonTraceProperties.Validity
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- | Take 'addr |-> v' pair from 'UTxOOut' and insert into map or add 'v' to value
-- already present. Used to fold over 'UTxO' to accumulate funds per address.
insertOrUpdate :: UTxOOut ShortHash -> Map (Addr ShortHash) (CompactValue ShortHash) -> Map (Addr ShortHash) (CompactValue ShortHash)
insertOrUpdate (UTxOOut a v) m =
  Map.insert
    a
    ( if Map.member a m
        then v <> (m Map.! a)
        else v
    )
    m

-- | Return True if at least half of the keys have non-trivial coin values to
-- spent, i.e., at least 2 coins per 50% of addresses.
isNotDustDist :: UTxO ShortHash -> UTxO ShortHash -> Bool
isNotDustDist initUtxo utxo' =
  utxoSize initUtxo
    <= 2 * Map.size (Map.filter (> Coin 1) (Map.map (getAdaAmount . compactValueToValue) valueMap))
  where
    valueMap = Map.foldr insertOrUpdate Map.empty (utxoMap utxo')

-- | This property states that a non-empty UTxO set in the genesis state has a
-- non-zero balance.
propPositiveBalance :: Property
propPositiveBalance =
  property $ do
    initialState <- Hedgehog.forAll (genNonemptyGenesisState (Proxy @ShortHash))
    utxoSize ((_utxo . _utxoState) initialState) /== 0
    (True === zeroV `lt` balance ((_utxo . _utxoState) initialState))

-- | This property states that the balance of the initial genesis state equals
-- the balance of the end ledger state plus the collected fees.
propPreserveBalanceInitTx :: Property
propPreserveBalanceInitTx =
  property $ do
    (_, steps, fee, ls, _, next) <- Hedgehog.forAll (genNonEmptyAndAdvanceTx (Proxy @ShortHash)) -- TODO should the forge be added up to over all tx's?!
    classify "non-trivial number of steps" (steps > 1)
    case next of
      Left _ -> failure
      Right ls' -> do
        classify
          "non-trivial wealth dist"
          (isNotDustDist ((_utxo . _utxoState) ls) ((_utxo . _utxoState) ls'))
        balance ((_utxo . _utxoState) ls) === balance ((_utxo . _utxoState) ls') <> (coinToValue fee) -- TODO check forge side

-- | Property (Preserve Balance Restricted to TxIns in Balance of TxOuts)
propBalanceTxInTxOut :: Property
propBalanceTxInTxOut = property $ do
  (l, steps, fee, txwits, l') <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  let tx = _body txwits
  let inps = txins tx
  classify "non-trivial valid ledger state" (steps > 1)
  classify
    "non-trivial wealth dist"
    (isNotDustDist ((_utxo . _utxoState) l) ((_utxo . _utxoState) l'))
  ((_forge tx) <> (balance $ inps <| ((_utxo . _utxoState) l))) === (balance (txouts tx) <> (coinToValue fee))

-- | Property (Preserve Outputs of Transaction)
propPreserveOutputs :: Property
propPreserveOutputs = property $ do
  (l, steps, _, txwits, l') <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  let tx = _body txwits
  classify "non-trivial valid ledger state" (steps > 1)
  classify
    "non-trivial wealth dist"
    (isNotDustDist ((_utxo . _utxoState) l) ((_utxo . _utxoState) l'))
  True === Map.isSubmapOf (utxoMap $ txouts tx) (utxoMap $ (_utxo . _utxoState) l')

-- | Property (Eliminate Inputs of Transaction)
propEliminateInputs :: Property
propEliminateInputs = property $ do
  (l, steps, _, txwits, l') <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  let tx = _body txwits
  classify "non-trivial valid ledger state" (steps > 1)
  classify
    "non-trivial wealth dist"
    (isNotDustDist ((_utxo . _utxoState) l) ((_utxo . _utxoState) l'))
  -- no element of 'txins tx' is a key in the 'UTxO' of l'
  Map.empty === Map.restrictKeys (utxoMap $ (_utxo . _utxoState) l') (txins tx)

-- | Property (Completeness and Collision-Freeness of new TxIds)
propUniqueTxIds :: Property
propUniqueTxIds = property $ do
  (l, steps, _, txwits, l') <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  let tx = _body txwits
  let origTxIds = collectIds <$> Map.keys (utxoMap ((_utxo . _utxoState) l))
  let newTxIds = collectIds <$> Map.keys (utxoMap (txouts tx))
  let txId = txid tx
  classify "non-trivial valid ledger state" (steps > 1)
  classify
    "non-trivial wealth dist"
    (isNotDustDist ((_utxo . _utxoState) l) ((_utxo . _utxoState) l'))
  True
    === ( all (== txId) newTxIds
            && notElem txId origTxIds
            && Map.isSubmapOf (utxoMap $ txouts tx) (utxoMap $ (_utxo . _utxoState) l')
        )
  where
    collectIds (TxIn txId _) = txId

-- | Property checks no double spend occurs in the currently generated 'TxWits'
-- transactions. Note: this is more a property of the current generator.
propNoDoubleSpend :: Property
propNoDoubleSpend = withTests 1000 $
  property $ do
    (_, _, _, _, txs, next) <- Hedgehog.forAll (genNonEmptyAndAdvanceTx (Proxy @ShortHash))
    case next of
      Left _ -> failure
      Right _ -> do
        let inputIndicesSet = unions $ map (\txwit -> fromSet $ (_inputs . _body) txwit) txs
        0
          === Data.MultiSet.size
            ( Data.MultiSet.filter
                (\idx -> 1 < Data.MultiSet.occur idx inputIndicesSet)
                inputIndicesSet
            )

-- | Classify mutated transaction into double-spends (validated and
-- non-validated). This is a property of the validator, i.e., no validated
-- transaction should ever be able to do a double spend.
classifyInvalidDoubleSpend :: Property
classifyInvalidDoubleSpend = withTests 1000 $
  property $ do
    (_, _, _, _, txs, LedgerValidation validationErrors _) <-
      Hedgehog.forAll (genNonEmptyAndAdvanceTx' (Proxy @ShortHash))
    let inputIndicesSet = unions $ map (\txwit -> fromSet $ (_inputs . _body) txwit) txs
    let multiSpentInputs =
          Data.MultiSet.size $
            Data.MultiSet.filter
              (\idx -> 1 < Data.MultiSet.occur idx inputIndicesSet)
              inputIndicesSet
    let isMultiSpend = 0 < multiSpentInputs
    classify "multi-spend, validation OK" (null validationErrors)
    classify "multi-spend, validation KO" (isMultiSpend && validationErrors /= [])
    classify "multi-spend" isMultiSpend
    True === (not isMultiSpend || validationErrors /= [])

propNonNegativeTxOuts :: Property
propNonNegativeTxOuts =
  withTests 100000 . property $ do
    (_, _, _, tx, _) <- Hedgehog.forAll (genStateTx (Proxy @ShortHash))
    all (\(TxOut _ v) -> lt zeroV v) (_outputs . _body $ tx) === True

-- | Mutations for Property 7.2
propBalanceTxInTxOut' :: Property
propBalanceTxInTxOut' =
  withTests 1000 $
    property $ do
      (l, _, fee, txwits, lv) <- Hedgehog.forAll (genStateTx (Proxy @ShortHash))
      let tx = _body txwits
      let inps = txins tx
      let getErrors (LedgerValidation valErrors _) = valErrors
      let balanceSource = balance $ inps <| ((_utxo . _utxoState) l)
      let balanceTarget = balance $ txouts tx
      let valErrors = getErrors lv
      let nonTrivial = not (eq balanceSource zeroV)
      let balanceOk = balanceSource == balanceTarget <> (coinToValue fee)
      classify "non-valid, OK" (valErrors /= [] && balanceOk && nonTrivial)
      if valErrors /= [] && balanceOk && nonTrivial
        then
          label $
            LabelName
              ( "inputs: " ++ show (show $ Set.size $ _inputs tx)
                  ++ " outputs: "
                  ++ show (show $ length $ _outputs tx)
                  ++ " balance l "
                  ++ show balanceSource
                  ++ " balance l' "
                  ++ show balanceTarget
                  ++ " txfee "
                  ++ show fee
                  ++ "\n  validationErrors: "
                  ++ show valErrors
              )
        else
          ( if valErrors /= [] && balanceOk
              then label "non-validated, OK, trivial"
              else
                ( if valErrors /= []
                    then label "non-validated, KO"
                    else label "validated"
                )
          )
      success

-- | Check that we correctly test redundant witnesses. We get the list of the
-- keys from the generator and use one to generate a new witness. If that key
-- was used to sign the transaction, then the transaction must validate. If a
-- new, redundant witness signature is added, the transaction must still
-- validate.
propCheckRedundantWitnessSet :: Property
propCheckRedundantWitnessSet = property $ do
  (l, steps, _, txwits, _, keyPairs) <- Hedgehog.forAll (genValidStateTxKeys (Proxy @ShortHash))
  let keyPair = fst $ head keyPairs
  let tx = _body txwits
  let witness = makeWitnessVKey (hashTxBody tx) keyPair
  let witnessSet = _witnessSet txwits
  let witnessSet' = witnessSet {addrWits = (Set.insert witness (addrWits witnessSet))}
  let txwits' = txwits {_witnessSet = witnessSet'}
  let l'' = asStateTransition (SlotNo $ fromIntegral steps) emptyPParams l txwits' (AccountState 0 0)
  classify
    "unneeded signature added"
    (not $ witness `Set.member` (addrWits witnessSet))
  case l'' of
    Right _ ->
      True
        === Set.null
          ( Set.filter (not . verifyWitVKey (hashTxBody tx)) (addrWits witnessSet')
          )
    _ -> failure

-- | Check that we correctly report missing witnesses.
propCheckMissingWitness :: Property
propCheckMissingWitness = property $ do
  (l, steps, _, txwits, _) <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  witnessList <-
    Hedgehog.forAll
      ( Gen.subsequence $
          Set.toList (addrWits $ _witnessSet txwits)
      )
  let witnessVKeySet'' = addrWits $ _witnessSet txwits
  let witnessVKeySet' = Set.fromList witnessList
  let l' =
        asStateTransition
          (SlotNo $ fromIntegral steps)
          emptyPParams
          l
          (txwits {_witnessSet = (_witnessSet txwits) {addrWits = witnessVKeySet'}})
          (AccountState 0 0)
  let isRealSubset =
        witnessVKeySet' `Set.isSubsetOf` witnessVKeySet''
          && witnessVKeySet' /= witnessVKeySet''
  classify "real subset" isRealSubset
  label $ LabelName ("witnesses:" ++ show (Set.size witnessVKeySet''))
  case l' of
    Left [MissingWitnesses] -> isRealSubset === True
    Right _ -> (witnessVKeySet' == witnessVKeySet'') === True
    _ -> failure

-- | Property (Preserve Balance)
propPreserveBalance :: Property
propPreserveBalance = property $ do
  (l, _, fee, tx, l') <- Hedgehog.forAll (genValidStateTx (Proxy @ShortHash))
  let destroyed =
        balance ((_utxo . _utxoState) l)
          <> (coinToValue $ (keyRefunds emptyPParams $ _body tx)) <> (_forge $ _body tx)
  let created =
        balance ((_utxo . _utxoState) l')
          <> (coinToValue $ fee
          + (totalDeposits emptyPParams ((_stPools . _pstate . _delegationState) l') $ toList $ (_certs . _body) tx))
  destroyed === created

-- | 'TestTree' of property-based testing properties.
nonTracePropertyTests :: TestTree
nonTracePropertyTests =
  testGroup
    "Non-Trace Property-Based Testing"
    [ testGroup
        "Ledger Genesis State"
        [ testProperty
            "non-empty genesis ledger state has non-zero balance"
            propPositiveBalance,
          testProperty
            "several transaction added to genesis ledger state"
            propPreserveBalanceInitTx
        ],
      testGroup
        "Property tests starting from valid ledger state"
        [ testProperty
            "preserve balance restricted to TxIns in Balance of outputs"
            propBalanceTxInTxOut,
          testProperty
            "Preserve outputs of transaction"
            propPreserveOutputs,
          testProperty
            "Eliminate Inputs of Transaction"
            propEliminateInputs,
          testProperty
            "Completeness and Collision-Freeness of new TxIds"
            propUniqueTxIds,
          testProperty
            "No Double Spend in valid ledger states"
            propNoDoubleSpend,
          testProperty
            "adding redundant witness"
            propCheckRedundantWitnessSet,
          testProperty
            "using subset of witness set"
            propCheckMissingWitness,
          testProperty
            "Correctly preserve balance"
            propPreserveBalance
        ],
      testGroup
        "Property tests with mutated transactions"
        [ testProperty
            "preserve balance of change in UTxO"
            propBalanceTxInTxOut',
          testProperty
            "Classify double spend"
            classifyInvalidDoubleSpend,
          testProperty
            "NonNegative TxOuts"
            propNonNegativeTxOuts
        ]
    ]
