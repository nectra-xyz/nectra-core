// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraConfigStorage} from "src/storage/NectraConfigStorage.sol";

/// @title NectraViews
/// @notice View functions for querying position, bucket, and global state
/// @dev Provides read-only access to protocol state with automatic state updates
abstract contract NectraViews is NectraBase {
    /// @notice Gets the complete position state
    /// @dev Updates position state before returning
    /// @param tokenId ID of the position to query
    /// @return Realtime position, bucket and global state
    function getPositionState(uint256 tokenId)
        external
        view
        returns (NectraLib.PositionState memory, NectraLib.BucketState memory, NectraLib.GlobalState memory)
    {
        (
            NectraLib.PositionState memory positionState,
            NectraLib.BucketState memory bucketState,
            NectraLib.GlobalState memory globalState
        ) = _loadAndUpdateState(tokenId);

        return (positionState, bucketState, globalState);
    }

    /// @notice Gets the complete bucket state
    /// @dev Updates bucket state before returning
    /// @param interestRate Interest rate of the bucket to query
    /// @return Realtime bucket and global state
    function getBucketState(uint256 interestRate)
        external
        view
        returns (NectraLib.BucketState memory, NectraLib.GlobalState memory)
    {
        (NectraLib.BucketState memory bucket, NectraLib.GlobalState memory global) =
            _loadAndUpdateBucketAndGlobalState(interestRate, _core()._epochs[interestRate]);

        return (bucket, global);
    }

    /// @notice Gets the complete global state
    /// @return Realtime global state
    function getGlobalState() external view returns (NectraLib.GlobalState memory) {
        return _loadGlobalState();
    }

    /// @notice Gets the system configuration values
    /// @return Complete set of system configuration values
    function getConfig() external view returns (NectraBase.SystemParams memory) {
        NectraConfigStorage.Layout storage c = _systemConfig();
        NectraBase.SystemParams memory params = NectraBase.SystemParams({
            nectraNFTAddress: c.NECTRA_NFT_ADDRESS,
            nusdTokenAddress: c.NUSD_TOKEN_ADDRESS,
            oracleAddress: c.ORACLE_ADDRESS,
            feeRecipientAddress: c.FEE_RECIPIENT_ADDRESS,
            minimumCollateral: c.MINIMUM_COLLATERAL,
            minimumDebt: c.MINIMUM_BORROW,
            maximumInterestRate: c.MAXIMUM_INTEREST_RATE,
            minimumInterestRate: c.MINIMUM_INTEREST_RATE,
            interestRateIncrement: c.INTEREST_RATE_INCREMENT,
            liquidationRatio: c.LIQUIDATION_RATIO,
            liquidatorRewardPercentage: c.LIQUIDATOR_REWARD_PERCENTAGE,
            liquidationPenaltyPercentage: c.LIQUIDATION_PENALTY_PERCENTAGE,
            fullLiquidationRatio: c.FULL_LIQUIDATION_RATIO,
            fullLiquidationFee: c.FULL_LIQUIDATOR_FEE,
            maximumLiquidatorReward: c.MAX_LIQUIDATOR_REWARD,
            issuanceRatio: c.ISSUANCE_RATIO,
            redemptionFeeDecayPeriod: c.REDEMPTION_FEE_DECAY_PERIOD,
            redemptionBaseFee: c.REDEMPTION_BASE_FEE,
            redemptionDynamicFeeScalar: c.REDEMPTION_DYNAMIC_FEE_SCALAR,
            redemptionFeeTreasuryThreshold: c.REDEMPTION_FEE_TREASURY_THRESHOLD,
            openFeePercentage: c.OPEN_FEE_PERCENTAGE,
            flashMintFee: c.FLASH_MINT_FEE,
            flashBorrowFee: c.FLASH_BORROW_FEE
        });

        return params;
    }
}
