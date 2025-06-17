// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

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
    /// @param totalDebtShares Total debt shares for all positions in this bucket
    /// @param globalDebtShares Debt shares this bucket owns in the global state
    /// @param accumulatedLiquidatedCollateralPerShare Accumulated liquidated collateral per share
    /// @param accumulatedRedeemedCollateralPerShare Accumulated redeemed collateral per share
    /// @param accumulatedInterestPerShare Accumulated interest per share
    /// @param lastGlobalAccumulatedLiquidatedCollateralPerShare Last global liquidated collateral per share
    /// @param lastGlobalAccumulatedLiquidatedDebtPerShare Last global liquidated debt per share
    /// @param lastUpdateTime Timestamp of last bucket update
    struct Bucket {
        uint256 totalDebtShares;
        uint256 globalDebtShares;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedRedeemedCollateralPerShare;
        uint256 accumulatedInterestPerShare;
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
    /// @param targetAccumulatedInterestPerBucketShare Target accumulated interest per share
    struct Position {
        uint256 interestRate;
        uint256 bucketEpoch;
        uint256 collateral;
        uint256 debtShares;
        uint256 lastBucketAccumulatedLiquidatedCollateralPerShare;
        uint256 lastBucketAccumulatedRedeemedCollateralPerShare;
        uint256 targetAccumulatedInterestPerBucketShare;
    }

    error InvalidAmount();
    error InsufficientCollateral();
    error FlashMintInProgress();
    error FlashBorrowInProgress();
    error InvalidCollateralPrice();

    uint256 internal immutable LIQUIDATION_RATIO;
    uint256 internal immutable FULL_LIQUIDATION_RATIO;
    uint256 internal immutable ISSUANCE_RATIO;

    uint256 internal immutable LIQUIDATION_PENALTY_PERCENTAGE;
    uint256 internal immutable LIQUIDATOR_REWARD_PERCENTAGE;
    uint256 internal immutable MAX_LIQUIDATOR_REWARD;
    uint256 internal immutable FULL_LIQUIDATOR_FEE;

    uint256 internal immutable REDEMPTION_FEE_DECAY_PERIOD;
    uint256 internal immutable REDEMPTION_BASE_FEE;
    uint256 internal immutable REDEMPTION_DYNAMIC_FEE_SCALAR;
    uint256 internal immutable REDEMPTION_FEE_TREASURY_THRESHOLD;

    uint256 internal immutable MAXIMUM_INTEREST_RATE;
    uint256 internal immutable MINIMUM_INTEREST_RATE;
    uint256 internal immutable INTEREST_RATE_INCREMENT;

    uint256 internal immutable OPEN_FEE_PERCENTAGE;

    uint256 internal immutable MINIMUM_COLLATERAL;
    uint256 internal immutable MINIMUM_BORROW;

    uint256 internal immutable FLASH_MINT_FEE;
    uint256 internal immutable FLASH_BORROW_FEE;

    address internal immutable NECTRA_NFT_ADDRESS;
    address internal immutable NUSD_TOKEN_ADDRESS;
    address internal immutable ORACLE_ADDRESS;
    address internal immutable FEE_RECIPIENT_ADDRESS;

    bool internal flashMintLock;
    uint256 internal flashBorrowLock;

    Globals internal _globals;

    // interestRate => epoch => Bucket
    mapping(uint256 => mapping(uint256 => Bucket)) internal _buckets;
    // interestRate => epoch
    mapping(uint256 => uint256) internal _epochs;
    // positionId => Position
    mapping(uint256 => Position) internal _positions;
    // interestRate => bucketBitMask
    mapping(uint256 => uint256) internal _bucketBitMasks;

    /// @notice Constructor arguments for initializing the contract
    /// @param nectraNFTAddress Address of the NectraNFT contract
    /// @param nusdTokenAddress Address of the NUSD token contract
    /// @param oracleAddress Address of the price oracle
    /// @param minimumCollateral Minimum amount of collateral required
    /// @param minimumDebt Minimum amount of debt allowed
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
    struct ConstructorArgs {
        address nectraNFTAddress;
        address nusdTokenAddress;
        address oracleAddress;
        uint256 minimumCollateral;
        uint256 minimumDebt;
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
    constructor(ConstructorArgs memory args) {
        NECTRA_NFT_ADDRESS = args.nectraNFTAddress;
        NUSD_TOKEN_ADDRESS = args.nusdTokenAddress;
        ORACLE_ADDRESS = args.oracleAddress;
        FEE_RECIPIENT_ADDRESS = args.feeRecipientAddress;

        MINIMUM_COLLATERAL = args.minimumCollateral;
        MINIMUM_BORROW = args.minimumDebt;

        MAXIMUM_INTEREST_RATE = args.maximumInterestRate;
        MINIMUM_INTEREST_RATE = args.minimumInterestRate;
        INTEREST_RATE_INCREMENT = args.interestRateIncrement;

        LIQUIDATION_RATIO = args.liquidationRatio;
        FULL_LIQUIDATION_RATIO = args.fullLiquidationRatio;
        ISSUANCE_RATIO = args.issuanceRatio;

        OPEN_FEE_PERCENTAGE = args.openFeePercentage;

        LIQUIDATION_PENALTY_PERCENTAGE = args.liquidationPenaltyPercentage;
        LIQUIDATOR_REWARD_PERCENTAGE = args.liquidatorRewardPercentage;
        MAX_LIQUIDATOR_REWARD = args.maximumLiquidatorReward;
        FULL_LIQUIDATOR_FEE = args.fullLiquidationFee;

        REDEMPTION_FEE_DECAY_PERIOD = args.redemptionFeeDecayPeriod;
        REDEMPTION_BASE_FEE = args.redemptionBaseFee;
        REDEMPTION_DYNAMIC_FEE_SCALAR = args.redemptionDynamicFeeScalar;
        REDEMPTION_FEE_TREASURY_THRESHOLD = args.redemptionFeeTreasuryThreshold;

        FLASH_MINT_FEE = args.flashMintFee;
        FLASH_BORROW_FEE = args.flashBorrowFee;
    }

    /// @notice Checks if flash minting is currently unlocked
    /// @dev Reverts if a flash mint operation is in progress
    function _requireFlashMintUnlocked() internal view {
        require(flashMintLock == false, FlashMintInProgress());
    }

    /// @notice Checks if flash borrowing is currently unlocked
    /// @dev Reverts if a flash borrow operation is in progress
    function _requireFlashBorrowUnlocked() internal view {
        require(flashBorrowLock == 0, FlashBorrowInProgress());
    }

    /// @notice Loads the current global state
    /// @return Global state of the system
    function _loadGlobalState() internal view returns (NectraLib.GlobalState memory) {
        Globals storage globals = _globals;
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
        Bucket storage bucketStorage = _buckets[interestRate][epoch];

        NectraLib.BucketState memory bucket = NectraLib.BucketState({
            interestRate: interestRate,
            epoch: epoch,
            totalDebtShares: bucketStorage.totalDebtShares,
            globalDebtShares: bucketStorage.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucketStorage.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucketStorage.accumulatedRedeemedCollateralPerShare,
            accumulatedInterestPerShare: bucketStorage.accumulatedInterestPerShare,
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
        Globals storage globals = _globals;
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
        Position storage positionStorage = _positions[tokenId];
        NectraLib.PositionState memory position = NectraLib.PositionState({
            tokenId: tokenId,
            collateral: positionStorage.collateral,
            debtShares: positionStorage.debtShares,
            lastBucketAccumulatedLiquidatedCollateralPerShare: positionStorage
                .lastBucketAccumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: positionStorage.lastBucketAccumulatedRedeemedCollateralPerShare,
            interestRate: positionStorage.interestRate,
            bucketEpoch: positionStorage.bucketEpoch,
            targetAccumulatedInterestPerBucketShare: positionStorage.targetAccumulatedInterestPerBucketShare
        });

        NectraLib.GlobalState memory global = _loadGlobalState();
        NectraLib.BucketState memory bucket = _loadBucketState(position.interestRate, position.bucketEpoch);

        NectraLib.updateBucketAndPosition(position, bucket, global, block.timestamp);

        uint256 currentEpoch = _epochs[position.interestRate];

        if (position.bucketEpoch < currentEpoch) {
            uint256 realizedFee = NectraLib.calculateOutstandingFee(position, bucket);
            global.fees += realizedFee;

            bucket = _loadAndUpdateBucketState(position.interestRate, currentEpoch, global);

            position = NectraLib.PositionState({
                tokenId: tokenId,
                collateral: position.collateral,
                debtShares: 0,
                lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                interestRate: bucket.interestRate,
                bucketEpoch: currentEpoch,
                targetAccumulatedInterestPerBucketShare: bucket.accumulatedInterestPerShare
            });

            NectraLib.modifyPosition(
                position,
                bucket,
                global,
                0, // collateral already accounted for
                int256(realizedFee)
            );
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

        _positions[position.tokenId] = Position({
            interestRate: position.interestRate,
            bucketEpoch: position.bucketEpoch,
            collateral: position.collateral,
            debtShares: position.debtShares,
            lastBucketAccumulatedLiquidatedCollateralPerShare: position.lastBucketAccumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: position.lastBucketAccumulatedRedeemedCollateralPerShare,
            targetAccumulatedInterestPerBucketShare: position.targetAccumulatedInterestPerBucketShare
        });

        _buckets[bucket.interestRate][_epochs[bucket.interestRate]] = Bucket({
            totalDebtShares: bucket.totalDebtShares,
            globalDebtShares: bucket.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            accumulatedInterestPerShare: bucket.accumulatedInterestPerShare,
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
        _globals = Globals({
            totalDebtShares: global.totalDebtShares,
            debt: global.debt,
            accumulatedLiquidatedCollateralPerShare: global.accumulatedLiquidatedCollateralPerShare,
            accumulatedLiquidatedDebtPerShare: global.accumulatedLiquidatedDebtPerShare,
            unrealizedLiquidatedDebt: global.unrealizedLiquidatedDebt
        });

        if (global.fees > 0) {
            NUSDToken(NUSD_TOKEN_ADDRESS).mint(FEE_RECIPIENT_ADDRESS, global.fees);
            global.fees = 0; // reset fees after minting
        }
    }

    /// @notice Finalizes bucket state changes
    /// @dev Updates bucket storage with the final state values
    /// @param bucket The final bucket state to store
    function _finalizeBucket(NectraLib.BucketState memory bucket) internal {
        _buckets[bucket.interestRate][_epochs[bucket.interestRate]] = Bucket({
            totalDebtShares: bucket.totalDebtShares,
            globalDebtShares: bucket.globalDebtShares,
            accumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            accumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            accumulatedInterestPerShare: bucket.accumulatedInterestPerShare,
            lastGlobalAccumulatedLiquidatedCollateralPerShare: bucket.lastGlobalAccumulatedLiquidatedCollateralPerShare,
            lastGlobalAccumulatedLiquidatedDebtPerShare: bucket.lastGlobalAccumulatedLiquidatedDebtPerShare,
            lastUpdateTime: bucket.lastUpdateTime
        });
    }

    /// @notice Calculates the index of a bucket based on its interest rate
    /// @param interestRate The interest rate to calculate the bucket index for
    /// @return The calculated bucket index
    function _getBucketIndex(uint256 interestRate) internal view returns (uint256) {
        return (interestRate - MINIMUM_INTEREST_RATE) / INTEREST_RATE_INCREMENT;
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
        return _bucketBitMasks[_getBucketBitMaskIndex(interestRate)];
    }

    /// @notice Stores a bit mask for a given interest rate
    /// @dev Updates the bit mask storage at the calculated bit mask index
    /// @param interestRate The interest rate to store the bit mask for
    /// @param bitMask The bit mask to store
    function _storeBucketBitMask(uint256 interestRate, uint256 bitMask) internal {
        _bucketBitMasks[_getBucketBitMaskIndex(interestRate)] = bitMask;
    }

    /// @notice Gets the collateral price with circuit breaker check
    /// @dev Reverts if the price is invalid or stale
    /// @return The current collateral price
    function _collateralPriceWithCircuitBreaker() internal view returns (uint256) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(ORACLE_ADDRESS).getLatestPrice();
        require(collateralPrice > 0 && isStale == false, InvalidCollateralPrice());
        return collateralPrice;
    }

    /// @notice Gets the collateral price without circuit breaker check
    /// @dev Returns 0 if the price is stale
    /// @return The current collateral price, or 0 if stale
    function _collateralPrice() internal view returns (uint256) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(ORACLE_ADDRESS).getLatestPrice();
        return !isStale ? collateralPrice : 0;
    }
}
