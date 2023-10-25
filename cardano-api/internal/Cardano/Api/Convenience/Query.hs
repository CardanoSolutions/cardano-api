{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Convenience query functions
--
module Cardano.Api.Convenience.Query (
    QueryConvenienceError(..),
    determineEra,
    -- * Simplest query related
    executeQueryCardanoMode,
    executeQueryAnyMode,

    queryStateForBalancedTx,
    renderQueryConvenienceError,
  ) where

import           Cardano.Api.Address
import           Cardano.Api.Certificate
import           Cardano.Api.Eon.ConwayEraOnwards (ConwayEraOnwards)
import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras
import           Cardano.Api.IO
import           Cardano.Api.IPC
import           Cardano.Api.IPC.Monad
import           Cardano.Api.Modes
import           Cardano.Api.NetworkId
import           Cardano.Api.ProtocolParameters
import           Cardano.Api.Query
import           Cardano.Api.Query.Expr
import           Cardano.Api.TxBody
import           Cardano.Api.Utils
import           Cardano.Api.Value

import qualified Cardano.Ledger.Api as L
import           Cardano.Ledger.CertState (DRepState (..))
import qualified Cardano.Ledger.Credential as L
import qualified Cardano.Ledger.Keys as L
import           Ouroboros.Consensus.HardFork.Combinator.AcrossEras (EraMismatch (..))

import           Control.Monad.Trans (MonadTrans (..))
import           Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import           Control.Monad.Trans.Except.Extra (left, onLeft, onNothing)
import           Data.Function ((&))
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (mapMaybe)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)

data QueryConvenienceError
  = AcqFailure AcquiringFailure
  | QueryEraMismatch EraMismatch
  | ByronEraNotSupported
  | EraConsensusModeMismatch !AnyConsensusMode !AnyCardanoEra
  | QceUnsupportedNtcVersion !UnsupportedNtcVersionError
  deriving Show

renderQueryConvenienceError :: QueryConvenienceError -> Text
renderQueryConvenienceError (AcqFailure e) =
  "Acquiring failure: " <> textShow e
renderQueryConvenienceError (QueryEraMismatch (EraMismatch ledgerEraName' otherEraName')) =
  "The era of the node and the tx do not match. " <>
  "The node is running in the " <> ledgerEraName' <>
  " era, but the transaction is for the " <> otherEraName' <> " era."
renderQueryConvenienceError ByronEraNotSupported =
  "Byron era not supported"
renderQueryConvenienceError (EraConsensusModeMismatch cMode anyCEra) =
  "Consensus mode and era mismatch. Consensus mode: " <> textShow cMode <>
  " Era: " <> textShow anyCEra
renderQueryConvenienceError (QceUnsupportedNtcVersion (UnsupportedNtcVersionError minNtcVersion ntcVersion)) =
  "Unsupported feature for the node-to-client protocol version.\n" <>
  "This query requires at least " <> textShow minNtcVersion <> " but the node negotiated " <> textShow ntcVersion <> ".\n" <>
  "Later node versions support later protocol versions (but development protocol versions are not enabled in the node by default)."

-- | A convenience function to query the relevant information, from
-- the local node, for Cardano.Api.Convenience.Construction.constructBalancedTx
queryStateForBalancedTx :: ()
  => CardanoEra era
  -> [TxIn]
  -> [Certificate era]
  -> LocalStateQueryExpr block point (QueryInMode CardanoMode) r IO
      ( Either
          QueryConvenienceError
          ( UTxO era
          , LedgerProtocolParameters era
          , EraHistory CardanoMode
          , SystemStart
          , Set PoolId
          , Map StakeCredential Lovelace
          , Map (L.Credential L.DRepRole L.StandardCrypto) Lovelace))
queryStateForBalancedTx era allTxIns certs = runExceptT $ do
  sbe <- requireShelleyBasedEra era
    & onNothing (left ByronEraNotSupported)

  qeInMode <- pure (toEraInMode era CardanoMode)
    & onNothing (left (EraConsensusModeMismatch (AnyConsensusMode CardanoMode) (anyCardanoEra era)))

  let stakeCreds = Set.fromList $ mapMaybe filterUnRegCreds certs
      drepCreds  = Set.fromList $ mapMaybe filterUnRegDRepCreds certs

  -- Query execution
  utxo <- lift (queryUtxo qeInMode sbe (QueryUTxOByTxIn (Set.fromList allTxIns)))
    & onLeft (left . QceUnsupportedNtcVersion)
    & onLeft (left . QueryEraMismatch)

  pparams <- lift (queryProtocolParameters qeInMode sbe)
    & onLeft (left . QceUnsupportedNtcVersion)
    & onLeft (left . QueryEraMismatch)

  eraHistory <- lift queryEraHistory
    & onLeft (left . QceUnsupportedNtcVersion)

  systemStart <- lift querySystemStart
    & onLeft (left . QceUnsupportedNtcVersion)

  stakePools <- lift (queryStakePools qeInMode sbe)
    & onLeft (left . QceUnsupportedNtcVersion)
    & onLeft (left . QueryEraMismatch)

  stakeDelegDeposits <-
    lift (queryStakeDelegDeposits qeInMode sbe stakeCreds)
      & onLeft (left . QceUnsupportedNtcVersion)
      & onLeft (left . QueryEraMismatch)

  drepDelegDeposits <-
    forEraInEon @ConwayEraOnwards era (pure mempty) $ \_ ->
      Map.map (fromShelleyLovelace . drepDeposit) <$>
      (lift (queryDRepState qeInMode sbe drepCreds)
          & onLeft (left . QceUnsupportedNtcVersion)
          & onLeft (left . QueryEraMismatch))

  pure (utxo, LedgerProtocolParameters pparams, eraHistory, systemStart, stakePools, stakeDelegDeposits, drepDelegDeposits)

-- | Query the node to determine which era it is in.
determineEra :: ()
  => ConsensusModeParams CardanoMode
  -> LocalNodeConnectInfo
  -> IO (Either AcquiringFailure AnyCardanoEra)
determineEra cModeParams localNodeConnInfo =
  case consensusModeOnly cModeParams of
    CardanoMode ->
      queryNodeLocalState localNodeConnInfo Nothing QueryCurrentEra

-- | Execute a query against the local node. The local
-- node must be in CardanoMode.
executeQueryCardanoMode :: ()
  => SocketPath
  -> NetworkId
  -> QueryInMode CardanoMode (Either EraMismatch result)
  -> IO (Either QueryConvenienceError result)
executeQueryCardanoMode socketPath nid q = runExceptT $ do
  let localNodeConnInfo =
        LocalNodeConnectInfo
          { localConsensusModeParams = CardanoModeParams (EpochSlots 21600)
          , localNodeNetworkId = nid
          , localNodeSocketPath = socketPath
          }

  ExceptT $ executeQueryAnyMode localNodeConnInfo q

-- | Execute a query against the local node in any mode.
executeQueryAnyMode :: forall result. ()
  => LocalNodeConnectInfo
  -> QueryInMode CardanoMode (Either EraMismatch result)
  -> IO (Either QueryConvenienceError result)
executeQueryAnyMode localNodeConnInfo q = runExceptT $ do
  lift (queryNodeLocalState localNodeConnInfo Nothing q)
    & onLeft (left . AcqFailure)
    & onLeft (left . QueryEraMismatch)
