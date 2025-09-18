// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";
import {NectraConfigStorage} from "src/storage/NectraConfigStorage.sol";
import {NectraCoreStorage} from "src/storage/NectraCoreStorage.sol";

/// @title NectraBase
/// @notice Base contract containing core state management and configuration for the Nectra protocol
/// @dev Updates global state, bucket state, and position state each time it is loaded
contract NectraBase {
    /// @notice Global state tracking for the entire system
    /// @param totalDebtShares Total debt shares for all buckets
    /// @param debt Total debt in the system
    /// @param accumulatedLiquidatedCollateralPerShare Accumulated collateral from liquidations per share
    /// @param accumulatedLiquidatedDebtPerShare Accumulated debt from liquidations per share
    /// @param unrealizedLiquidatedDebt In-flight debt from liquidations yet to be realized
    struct Globals {
        uint256 totalDebtShares;
        uint256 debt;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedLiquidatedDebtPerShare;
        uint256 unrealizedLiquidatedDebt;
    }

    /// @notice State tracking for an interest rate bucket
    /// @param collateral Amount of collateral in the bucket
    /// @param totalDebtShares Total debt shares for all positions in this bucket
    /// @param globalDebtShares Debt shares this bucket owns in the global state
    /// @param accumulatedLiquidatedCollateralPerShare Accumulated liquidated collateral per share
    /// @param accumulatedRedeemedCollateralPerShare Accumulated redeemed collateral per share
    /// @param lastGlobalAccumulatedLiquidatedCollateralPerShare Last global liquidated collateral per share
    /// @param lastGlobalAccumulatedLiquidatedDebtPerShare Last global liquidated debt per share
    /// @param lastUpdateTime Timestamp of last bucket update
    struct Bucket {
        uint256 collateral;
        uint256 totalDebtShares;
        uint256 globalDebtShares;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedRedeemedCollateralPerShare;
        uint256 lastGlobalAccumulatedLiquidatedCollateralPerShare;
        uint256 lastGlobalAccumulatedLiquidatedDebtPerShare;
        uint256 lastUpdateTime;
    }

    /// @notice State tracking for a position
    /// @param interestRate Interest rate bucket for this position
    /// @param bucketEpoch Current epoch of the bucket
    /// @param collateral Amount of collateral in the position
    /// @param debtShares Number of debt shares for the position in its bucket
    /// @param lastBucketAccumulatedLiquidatedCollateralPerShare Last bucket liquidated collateral per share
    /// @param lastBucketAccumulatedRedeemedCollateralPerShare Last bucket redeemed collateral per share
    struct Position {
        uint256 interestRate;
        uint256 bucketEpoch;
        uint256 collateral;
        uint256 debtShares;
        uint256 lastBucketAccumulatedLiquidatedCollateralPerShare;
        uint256 lastBucketAccumulatedRedeemedCollateralPerShare;
    }

    error InvalidAmount();
    error InsufficientCollateral();
    error FlashMintInProgress();
    error FlashBorrowInProgress();
    error InterestRateTooHigh(uint256 interestRate, uint256 maximumInterestRate);
    error InterestRateTooLow(uint256 interestRate, uint256 minimumInterestRate);
    error InvalidInterestRate();
    error InvalidCollateralPrice();

    // Namespaced storage accessors
    function _systemConfig() internal pure returns (NectraConfigStorage.Layout storage s) {
        return NectraConfigStorage.layout();
    }

    function _core() internal pure returns (NectraCoreStorage.Layout storage s) {
        return NectraCoreStorage.layout();
    }

    /// @notice Constructor arguments for initializing the contract
    /// @param nectraNFTAddress Address of the NectraNFT contract
    /// @param nusdTokenAddress Address of the NUSD token contract
    /// @param oracleAddress Address of the price oracle
    /// @param minimumCollateral Minimum amount of collateral required
    /// @param minimumDebt Minimum amount of debt allowed
    /// @param systemInterestRate System set interest rate
    /// @param maximumInterestRate Maximum allowed interest rate
    /// @param minimumInterestRate Minimum allowed interest rate
    /// @param interestRateIncrement Step size for interest rate changes
    /// @param redemptionFeeDecayPeriod Period for redemption fee decay
    /// @param redemptionBaseFee Base fee for redemptions
    /// @param redemptionDynamicFeeScalar Scalar for dynamic redemption fee
    /// @param redemptionFeeTreasuryThreshold Threshold for treasury fee
    /// @param openFeePercentage Fee percentage for opening positions
    /// @param liquidationRatio Ratio for liquidation threshold
    /// @param fullLiquidationRatio Ratio for full liquidation threshold
    /// @param issuanceRatio Ratio for maximum debt issuance
    /// @param liquidationPenaltyPercentage Penalty percentage for liquidation
    /// @param liquidatorRewardPercentage Reward percentage for liquidators
    /// @param maximumLiquidatorReward Maximum reward for liquidators
    /// @param fullLiquidationFee Fee for full liquidation
    /// @param feeRecipientAddress Address to receive system fees
    /// @param flashMintFee Fee for flash minting
    /// @param flashBorrowFee Fee for flash borrowing
    struct SystemParams {
        address nectraNFTAddress;
        address nusdTokenAddress;
        address oracleAddress;
        uint256 minimumCollateral;
        uint256 minimumDebt;
        uint256 systemInterestRate;
        uint256 maximumInterestRate;
        uint256 minimumInterestRate;
        uint256 interestRateIncrement;
        uint256 redemptionFeeDecayPeriod;
        uint256 redemptionBaseFee;
        uint256 redemptionDynamicFeeScalar;
        uint256 redemptionFeeTreasuryThreshold;
        uint256 openFeePercentage;
        uint256 liquidationRatio;
        uint256 fullLiquidationRatio;
        uint256 issuanceRatio;
        uint256 liquidationPenaltyPercentage;
        uint256 liquidatorRewardPercentage;
        uint256 maximumLiquidatorReward;
        uint256 fullLiquidationFee;
        address feeRecipientAddress;
        uint256 flashMintFee;
        uint256 flashBorrowFee;
    }

    /// @param args Constructor arguments containing all configuration parameters
    function setSystemParams(SystemParams memory args) internal {
        NectraConfigStorage.Layout storage c = _systemConfig();
        c.NECTRA_NFT_ADDRESS = args.nectraNFTAddress;
        c.NUSD_TOKEN_ADDRESS = args.nusdTokenAddress;
        c.ORACLE_ADDRESS = args.oracleAddress;
        c.FEE_RECIPIENT_ADDRESS = args.feeRecipientAddress;

        c.MINIMUM_COLLATERAL = args.minimumCollateral;
        c.MINIMUM_BORROW = args.minimumDebt;

        c.SYSTEM_INTEREST_RATE = args.systemInterestRate;
        c.MAXIMUM_INTEREST_RATE = args.maximumInterestRate;
        c.MINIMUM_INTEREST_RATE = args.minimumInterestRate;
        c.INTEREST_RATE_INCREMENT = args.interestRateIncrement;

        c.LIQUIDATION_RATIO = args.liquidationRatio;
        c.FULL_LIQUIDATION_RATIO = args.fullLiquidationRatio;
        c.ISSUANCE_RATIO = args.issuanceRatio;

        c.OPEN_FEE_PERCENTAGE = args.openFeePercentage;

        c.LIQUIDATION_PENALTY_PERCENTAGE = args.liquidationPenaltyPercentage;
        c.LIQUIDATOR_REWARD_PERCENTAGE = args.liquidatorRewardPercentage;
        c.MAX_LIQUIDATOR_REWARD = args.maximumLiquidatorReward;
        c.FULL_LIQUIDATOR_FEE = args.fullLiquidationFee;

        c.REDEMPTION_FEE_DECAY_PERIOD = args.redemptionFeeDecayPeriod;
        c.REDEMPTION_BASE_FEE = args.redemptionBaseFee;
        c.REDEMPTION_DYNAMIC_FEE_SCALAR = args.redemptionDynamicFeeScalar;
        c.REDEMPTION_FEE_TREASURY_THRESHOLD = args.redemptionFeeTreasuryThreshold;

        c.FLASH_MINT_FEE = args.flashMintFee;
        c.FLASH_BORROW_FEE = args.flashBorrowFee;
    }

    /// @notice Checks if flash minting is currently unlocked
    /// @dev Reverts if a flash mint operation is in progress
    function _requireFlashMintUnlocked() internal view {
        require(_core().flashMintLock == false, FlashMintInProgress());
    }

    /// @notice Checks if flash borrowing is currently unlocked
    /// @dev Reverts if a flash borrow operation is in progress
    function _requireFlashBorrowUnlocked() internal view {
        require(_core().flashBorrowLock == 0, FlashBorrowInProgress());
    }

    /// @notice Loads the current global state
    /// @return Global state of the system
    function _loadGlobalState() internal view returns (NectraLib.GlobalState memory) {
        NectraCoreStorage.Globals storage globals = _core()._globals;
        return NectraLib.GlobalState({
            totalDebtShares: globals.totalDebtShares,
            debt: globals.debt,
            accumulatedLiquidatedCollateralPerShare: globals.accumulatedLiquidatedCollateralPerShare,
            accumulatedLiquidatedDebtPerShare: globals.accumulatedLiquidatedDebtPerShare,
            unrealizedLiquidatedDebt: globals.unrealizedLiquidatedDebt,
            fees: 0
        });
    }

    /// @notice Loads the state of a specific bucket
    /// @param interestRate Interest rate of the bucket
    /// @param epoch Current epoch of the bucket
    /// @return Bucket state
    function _loadBucketState(uint256 interestRate, uint256 epoch)
        internal
        view
        returns (NectraLib.BucketState memory)
    {
        NectraCoreStorage.Bucket storage bucketStorage = _core()._buckets[interestRate][epoch];

        NectraLib.BucketState memory bucket = NectraLib.BucketState({
            interestRate: interestRate,
            epoch: epoch,
            collateral: bucketStorage.collateral,
            totalDebtShares: bucketStorage.totalDebtShares,
            globalDebtShares: bucketStorage.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucketStorage.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucketStorage.accumulatedRedeemedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedCollateralPerShare: bucketStorage
                .lastGlobalAccumulatedLiquidatedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedDebtPerShare: bucketStorage.lastGlobalAccumulatedLiquidatedDebtPerShare,
            lastUpdateTime: bucketStorage.lastUpdateTime
        });

        return bucket;
    }

    /// @notice Loads and updates the state of a specific bucket
    /// @param interestRate Interest rate of the bucket
    /// @param epoch Current epoch of the bucket
    /// @param global Current global state
    /// @return Updated bucket state
    function _loadAndUpdateBucketState(uint256 interestRate, uint256 epoch, NectraLib.GlobalState memory global)
        internal
        view
        returns (NectraLib.BucketState memory)
    {
        NectraLib.BucketState memory bucket = _loadBucketState(interestRate, epoch);
        NectraLib.updateBucket(bucket, global, block.timestamp);
        return bucket;
    }

    /// @notice Loads and updates both bucket and global state
    /// @param interestRate Interest rate of the bucket
    /// @param epoch Current epoch of the bucket
    /// @return Updated bucket state
    /// @return Updated global state
    function _loadAndUpdateBucketAndGlobalState(uint256 interestRate, uint256 epoch)
        internal
        view
        returns (NectraLib.BucketState memory, NectraLib.GlobalState memory)
    {
        NectraCoreStorage.Globals storage globals = _core()._globals;
        NectraLib.GlobalState memory global = NectraLib.GlobalState({
            totalDebtShares: globals.totalDebtShares,
            debt: globals.debt,
            accumulatedLiquidatedCollateralPerShare: globals.accumulatedLiquidatedCollateralPerShare,
            accumulatedLiquidatedDebtPerShare: globals.accumulatedLiquidatedDebtPerShare,
            unrealizedLiquidatedDebt: globals.unrealizedLiquidatedDebt,
            fees: 0
        });

        NectraLib.BucketState memory bucket = _loadAndUpdateBucketState(interestRate, epoch, global);

        return (bucket, global);
    }

    /// @notice Loads and updates the state of a position
    /// @param tokenId ID of the position
    /// @return Updated position state
    /// @return Updated bucket state
    /// @return Updated global state
    function _loadAndUpdateState(uint256 tokenId)
        internal
        view
        returns (NectraLib.PositionState memory, NectraLib.BucketState memory, NectraLib.GlobalState memory)
    {
        NectraCoreStorage.Position storage positionStorage = _core()._positions[tokenId];
        NectraLib.PositionState memory position = NectraLib.PositionState({
            tokenId: tokenId,
            collateral: positionStorage.collateral,
            debtShares: positionStorage.debtShares,
            lastBucketAccumulatedLiquidatedCollateralPerShare: positionStorage
                .lastBucketAccumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: positionStorage.lastBucketAccumulatedRedeemedCollateralPerShare,
            interestRate: positionStorage.interestRate,
            bucketEpoch: positionStorage.bucketEpoch
        });

        NectraLib.GlobalState memory global = _loadGlobalState();
        NectraLib.BucketState memory bucket = _loadBucketState(position.interestRate, position.bucketEpoch);

        NectraLib.updateBucketAndPosition(position, bucket, global, block.timestamp);

        uint256 currentEpoch = _core()._epochs[position.interestRate];

        // update position if it is in an older bucket epoch
        // the debt for the position will be 0 since the epoch only increases when a bucket is fully redeemed
        if (position.bucketEpoch < currentEpoch) {
            uint256 collateral = position.collateral;

            bucket = _loadAndUpdateBucketState(position.interestRate, currentEpoch, global);

            position = NectraLib.PositionState({
                tokenId: tokenId,
                collateral: 0,
                debtShares: 0,
                lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                interestRate: bucket.interestRate,
                bucketEpoch: currentEpoch
            });

            NectraLib.modifyPosition(position, bucket, global, int256(collateral), 0);
        }

        return (position, bucket, global);
    }

    /// @notice Finalizes the state changes for a position, bucket, and global state
    /// @dev Updates storage with the final state values and handles bucket bit mask updates
    /// @param position The final position state to store
    /// @param bucket The final bucket state to store
    /// @param global The final global state to store
    function _finalize(
        NectraLib.PositionState memory position,
        NectraLib.BucketState memory bucket,
        NectraLib.GlobalState memory global
    ) internal {
        uint256 bucketBitMask = _bucketBitMask(position.interestRate);
        if (NectraLib.calculateBucketDebt(bucket, global, NectraMathLib.Rounding.Up) > 0) {
            // set the bit in the bucket bit mask
            bucketBitMask |= (1 << (_getBucketIndex(position.interestRate) % 256));
        } else {
            // clear the bit in the bucket bit mask
            bucketBitMask &= ~(1 << (_getBucketIndex(position.interestRate) % 256));
        }
        _storeBucketBitMask(position.interestRate, bucketBitMask);

        _core()._positions[position.tokenId] = NectraCoreStorage.Position({
            interestRate: position.interestRate,
            bucketEpoch: position.bucketEpoch,
            collateral: position.collateral,
            debtShares: position.debtShares,
            lastBucketAccumulatedLiquidatedCollateralPerShare: position.lastBucketAccumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: position.lastBucketAccumulatedRedeemedCollateralPerShare
        });

        _core()._buckets[bucket.interestRate][_core()._epochs[bucket.interestRate]] = NectraCoreStorage.Bucket({
            collateral: bucket.collateral,
            totalDebtShares: bucket.totalDebtShares,
            globalDebtShares: bucket.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedCollateralPerShare: bucket.lastGlobalAccumulatedLiquidatedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedDebtPerShare: bucket.lastGlobalAccumulatedLiquidatedDebtPerShare,
            lastUpdateTime: bucket.lastUpdateTime
        });

        _finalizeGlobal(global);
    }

    /// @notice Finalizes global state changes and handles fee distribution
    /// @dev Updates global storage and mints fees to the fee recipient if any are accumulated
    /// @param global The final global state to store
    function _finalizeGlobal(NectraLib.GlobalState memory global) internal {
        NectraCoreStorage.Globals storage g = _core()._globals;
        g.totalDebtShares = global.totalDebtShares;
        g.debt = global.debt;
        g.accumulatedLiquidatedCollateralPerShare = global.accumulatedLiquidatedCollateralPerShare;
        g.accumulatedLiquidatedDebtPerShare = global.accumulatedLiquidatedDebtPerShare;
        g.unrealizedLiquidatedDebt = global.unrealizedLiquidatedDebt;

        if (global.fees > 0) {
            NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).mint(_systemConfig().FEE_RECIPIENT_ADDRESS, global.fees);
            global.fees = 0; // reset fees after minting
        }
    }

    /// @notice Finalizes bucket state changes
    /// @dev Updates bucket storage with the final state values
    /// @param bucket The final bucket state to store
    function _finalizeBucket(NectraLib.BucketState memory bucket) internal {
        _core()._buckets[bucket.interestRate][_core()._epochs[bucket.interestRate]] = NectraCoreStorage.Bucket({
            collateral: bucket.collateral,
            totalDebtShares: bucket.totalDebtShares,
            globalDebtShares: bucket.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedCollateralPerShare: bucket.lastGlobalAccumulatedLiquidatedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedDebtPerShare: bucket.lastGlobalAccumulatedLiquidatedDebtPerShare,
            lastUpdateTime: bucket.lastUpdateTime
        });
    }

    /// @notice Calculates the index of a bucket based on its interest rate
    /// @param interestRate The interest rate to calculate the bucket index for
    /// @return The calculated bucket index
    function _getBucketIndex(uint256 interestRate) internal view returns (uint256) {
        return (interestRate - _systemConfig().MINIMUM_INTEREST_RATE) / _systemConfig().INTEREST_RATE_INCREMENT;
    }

    /// @notice Calculates the index for the bucket bit mask
    /// @param interestRate The interest rate to calculate the bit mask index for
    /// @return The calculated bit mask index
    function _getBucketBitMaskIndex(uint256 interestRate) internal view returns (uint256) {
        return _getBucketIndex(interestRate) / 256;
    }

    /// @notice Retrieves the bit mask for a given interest rate
    /// @dev Uses the bit mask index to look up the stored bit mask
    /// @param interestRate The interest rate to get the bit mask for
    /// @return bitMask The stored bit mask for the interest rate
    function _bucketBitMask(uint256 interestRate) internal view returns (uint256 bitMask) {
        return _core()._bucketBitMasks[_getBucketBitMaskIndex(interestRate)];
    }

    /// @notice Stores a bit mask for a given interest rate
    /// @dev Updates the bit mask storage at the calculated bit mask index
    /// @param interestRate The interest rate to store the bit mask for
    /// @param bitMask The bit mask to store
    function _storeBucketBitMask(uint256 interestRate, uint256 bitMask) internal {
        _core()._bucketBitMasks[_getBucketBitMaskIndex(interestRate)] = bitMask;
    }

    /// @notice Gets the system set interest rate
    /// @return The system set interest rate
    function _systemInterestRate() internal view returns (uint256) {
        return _systemConfig().SYSTEM_INTEREST_RATE;
    }

    /// @notice Sets the system set interest rate
    /// @param systemInterestRate The system set interest rate to set
    function _setSystemInterestRate(uint256 systemInterestRate) internal {
        require(systemInterestRate <= _systemConfig().MAXIMUM_INTEREST_RATE, InterestRateTooHigh(systemInterestRate, _systemConfig().MAXIMUM_INTEREST_RATE));
        require(systemInterestRate >= _systemConfig().MINIMUM_INTEREST_RATE, InterestRateTooLow(systemInterestRate, _systemConfig().MINIMUM_INTEREST_RATE));
        require(systemInterestRate % _systemConfig().INTEREST_RATE_INCREMENT == 0, InvalidInterestRate());

        _systemConfig().SYSTEM_INTEREST_RATE = systemInterestRate;
    }

    /// @notice Gets the collateral price with circuit breaker check
    /// @dev Reverts if the price is invalid or stale
    /// @return The current collateral price
    function _collateralPriceWithCircuitBreaker() internal view returns (uint256) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(_systemConfig().ORACLE_ADDRESS).getLatestPrice();
        require(collateralPrice > 0 && isStale == false, InvalidCollateralPrice());
        return collateralPrice;
    }

    /// @notice Gets the collateral price without circuit breaker check
    /// @dev Returns 0 if the price is stale
    /// @return The current collateral price, or 0 if stale
    function _collateralPrice() internal view returns (uint256) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(_systemConfig().ORACLE_ADDRESS).getLatestPrice();
        return !isStale ? collateralPrice : 0;
    }
}
