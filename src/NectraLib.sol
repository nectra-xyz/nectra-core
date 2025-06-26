// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";

/// @title NectraLib
/// @notice Core library containing state update and calculation functions for the Nectra protocol
/// @dev Handles position, bucket, and global state updates with interest and liquidation calculations
library NectraLib {
    using FixedPointMathLib for uint256;
    using NectraMathLib for uint256;
    using NectraMathLib for int256;
    using SafeCastLib for uint256;

    /// @notice Global state tracking for the entire system
    /// @param debt Total debt in the system, should be equal to nUSD totalSupply + fees + unrealizedLiquidatedDebt
    /// @param totalDebtShares Total debt shares across all buckets
    /// @param accumulatedLiquidatedCollateralPerShare Accumulated collateral from liquidations per share
    /// @param accumulatedLiquidatedDebtPerShare Accumulated debt from liquidations per share
    /// @param unrealizedLiquidatedDebt In-flight debt from liquidations yet to be realized
    /// @param fees Interest that can be minted to the treasury
    struct GlobalState {
        uint256 debt;
        uint256 totalDebtShares;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedLiquidatedDebtPerShare;
        uint256 unrealizedLiquidatedDebt;
        uint256 fees;
    }

    /// @notice State tracking for an interest rate bucket
    /// @param interestRate Interest rate of the bucket
    /// @param epoch Current epoch of the bucket
    /// @param totalDebtShares Sum of all debt shares held by positions in the bucket
    /// @param globalDebtShares Number of shares held by the bucket in the global state
    /// @param accumulatedLiquidatedCollateralPerShare Accumulated liquidated collateral per share
    /// @param accumulatedRedeemedCollateralPerShare Accumulated redeemed collateral per share
    /// @param accumulatedInterestPerShare Accumulated interest per share
    /// @param lastGlobalAccumulatedLiquidatedCollateralPerShare Last global liquidated collateral per share
    /// @param lastGlobalAccumulatedLiquidatedDebtPerShare Last global liquidated debt per share
    /// @param lastUpdateTime Timestamp of last bucket update
    struct BucketState {
        uint256 interestRate;
        uint256 epoch;
        uint256 collateral;
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
    /// @param tokenId ID of the position
    /// @param interestRate Interest rate bucket for this position
    /// @param bucketEpoch Current epoch of the bucket
    /// @param collateral Amount of collateral in the position
    /// @param debtShares Number of debt shares for the position in its bucket
    /// @param lastBucketAccumulatedLiquidatedCollateralPerShare Last bucket liquidated collateral per share
    /// @param lastBucketAccumulatedRedeemedCollateralPerShare Last bucket redeemed collateral per share
    /// @param targetAccumulatedInterestPerBucketShare Target accumulated interest per share
    struct PositionState {
        uint256 tokenId;
        uint256 interestRate;
        uint256 bucketEpoch;
        uint256 collateral;
        uint256 debtShares;
        uint256 lastBucketAccumulatedLiquidatedCollateralPerShare;
        uint256 lastBucketAccumulatedRedeemedCollateralPerShare;
        uint256 targetAccumulatedInterestPerBucketShare;
    }

    /// @notice Updates a bucket's state with interest and liquidation calculations
    /// @dev Handles socialization of liquidated debt/collateral and interest accrual
    /// @param bucket The bucket state to update
    /// @param global The global state to update
    /// @param currentTimestamp Current block timestamp
    function updateBucket(BucketState memory bucket, GlobalState memory global, uint256 currentTimestamp)
        internal
        pure
    {
        if (bucket.globalDebtShares > 0 && global.totalDebtShares > 0) {
            BucketState memory initialBucketState;
            GlobalState memory initialGlobalState;

            copy(initialBucketState, bucket);
            copy(initialGlobalState, global);

            // First socialize liquidated debt
            {
                uint256 debtPerShareDiff = initialGlobalState.accumulatedLiquidatedDebtPerShare
                    - initialBucketState.lastGlobalAccumulatedLiquidatedDebtPerShare;

                uint256 newDebt = debtPerShareDiff.mulWadUp(initialBucketState.globalDebtShares);

                // realize debt
                uint256 newGlobalDebtShares = newDebt.convertToShares(
                    initialGlobalState.debt, initialGlobalState.totalDebtShares, NectraMathLib.Rounding.Up
                );

                bucket.globalDebtShares += newGlobalDebtShares;
                global.totalDebtShares += newGlobalDebtShares;
                global.debt += newDebt;
                global.unrealizedLiquidatedDebt =
                    NectraMathLib.saturatingAdd(global.unrealizedLiquidatedDebt, -int256(newDebt));
            }

            // Socialize liquidated collateral
            {
                uint256 collateralPerShareDiff = initialGlobalState.accumulatedLiquidatedCollateralPerShare
                    - initialBucketState.lastGlobalAccumulatedLiquidatedCollateralPerShare;

                uint256 newCollateral = collateralPerShareDiff.mulWad(initialBucketState.globalDebtShares);

                bucket.accumulatedLiquidatedCollateralPerShare +=
                    newCollateral.divWad(initialBucketState.totalDebtShares);
                bucket.collateral += newCollateral;
            }

            // calculate and apply interest
            if (currentTimestamp > bucket.lastUpdateTime) {
                uint256 interest = calculateInterest(
                    calculateBucketDebt(initialBucketState, initialGlobalState, NectraMathLib.Rounding.Up),
                    initialBucketState.interestRate,
                    currentTimestamp - initialBucketState.lastUpdateTime
                );
                uint256 newGlobalDebtShares = interest.convertToShares(
                    initialGlobalState.debt, initialGlobalState.totalDebtShares, NectraMathLib.Rounding.Up
                );

                bucket.globalDebtShares += newGlobalDebtShares;
                bucket.accumulatedInterestPerShare += interest.divWad(initialBucketState.totalDebtShares);
                global.totalDebtShares += newGlobalDebtShares;
                global.debt += interest;
                global.fees += interest;
            }
        }

        bucket.lastUpdateTime = currentTimestamp;
        bucket.lastGlobalAccumulatedLiquidatedDebtPerShare = global.accumulatedLiquidatedDebtPerShare;
        bucket.lastGlobalAccumulatedLiquidatedCollateralPerShare = global.accumulatedLiquidatedCollateralPerShare;
    }

    /// @notice Updates both bucket and position state
    /// @dev Updates bucket first, then applies changes to position
    /// @param position The position state to update
    /// @param bucket The bucket state to update
    /// @param global The global state to update
    /// @param currentTimestamp Current block timestamp
    function updateBucketAndPosition(
        PositionState memory position,
        BucketState memory bucket,
        GlobalState memory global,
        uint256 currentTimestamp
    ) internal pure {
        // Ensure the bucket state is updated before the position state
        updateBucket(bucket, global, currentTimestamp);

        // Socialize liquidated collateral
        {
            uint256 collateralPerShareDiff = bucket.accumulatedLiquidatedCollateralPerShare
                - position.lastBucketAccumulatedLiquidatedCollateralPerShare;

            uint256 newCollateral = collateralPerShareDiff.mulWad(position.debtShares);

            position.collateral += newCollateral;
            position.lastBucketAccumulatedLiquidatedCollateralPerShare = bucket.accumulatedLiquidatedCollateralPerShare;
        }

        // Remove redeemed collateral
        {
            uint256 collateralPerShareDiff =
                bucket.accumulatedRedeemedCollateralPerShare - position.lastBucketAccumulatedRedeemedCollateralPerShare;
            uint256 redeemedCollateral = collateralPerShareDiff.mulWadUp(position.debtShares);

            position.collateral = NectraMathLib.saturatingAdd(position.collateral, -(redeemedCollateral).toInt256());
            position.lastBucketAccumulatedRedeemedCollateralPerShare = bucket.accumulatedRedeemedCollateralPerShare;
        }

        position.targetAccumulatedInterestPerBucketShare = position.targetAccumulatedInterestPerBucketShare
            > bucket.accumulatedInterestPerShare
            ? position.targetAccumulatedInterestPerBucketShare
            : bucket.accumulatedInterestPerShare;
    }

    /// @notice Calculates outstanding fees for a position
    /// @dev Computes fees based on position's target interest and current bucket state
    /// @param position The position to calculate fees for
    /// @param bucket The bucket containing the position
    /// @return The amount of outstanding fees
    function calculateOutstandingFee(PositionState memory position, BucketState memory bucket)
        internal
        pure
        returns (uint256)
    {
        uint256 outstandingFeesPerShare = position.targetAccumulatedInterestPerBucketShare
            > bucket.accumulatedInterestPerShare
            ? position.targetAccumulatedInterestPerBucketShare - bucket.accumulatedInterestPerShare
            : 0;

        return outstandingFeesPerShare.mulWad(position.debtShares);
    }

    /// @notice Calculates total debt for a bucket
    /// @dev Converts bucket's global debt shares to actual debt amount
    /// @param bucket The bucket to calculate debt for
    /// @param global The global state
    /// @param rounding The rounding mode to use
    /// @return The bucket's total debt
    function calculateBucketDebt(BucketState memory bucket, GlobalState memory global, NectraMathLib.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return bucket.globalDebtShares.convertToAssets(global.debt, global.totalDebtShares, rounding);
    }

    /// @notice Calculates debt for a position
    /// @dev Computes position's debt based on its shares and bucket state
    /// @param position The position to calculate debt for
    /// @param bucket The bucket containing the position
    /// @param global The global state
    /// @param rounding The rounding mode to use
    /// @return The position's debt
    function calculatePositionDebt(
        PositionState memory position,
        BucketState memory bucket,
        GlobalState memory global,
        NectraMathLib.Rounding rounding
    ) internal pure returns (uint256) {
        (uint256 positionDebt,) = calculateBucketAndPositionDebt(position, bucket, global, rounding);
        return positionDebt;
    }

    /// @notice Calculates both bucket and position debt
    /// @dev Computes debt for both bucket and position in one call
    /// @param position The position to calculate debt for
    /// @param bucket The bucket containing the position
    /// @param global The global state
    /// @param rounding The rounding mode to use
    /// @return positionDebt The position's debt
    /// @return bucketDebt The bucket's total debt
    function calculateBucketAndPositionDebt(
        PositionState memory position,
        BucketState memory bucket,
        GlobalState memory global,
        NectraMathLib.Rounding rounding
    ) internal pure returns (uint256, uint256) {
        uint256 bucketDebt = calculateBucketDebt(bucket, global, rounding);
        uint256 positionDebt = position.debtShares.convertToAssets(bucketDebt, bucket.totalDebtShares, rounding);
        return (positionDebt, bucketDebt);
    }

    /// @notice Modifies a position's state
    /// @dev Updates position, bucket, and global state with collateral and debt changes
    /// @param position The position to modify
    /// @param bucket The bucket containing the position
    /// @param global The global state
    /// @param collateralDiff Change in collateral amount
    /// @param debtDiff Change in debt amount
    function modifyPosition(
        PositionState memory position,
        BucketState memory bucket,
        GlobalState memory global,
        int256 collateralDiff,
        int256 debtDiff
    ) internal pure {
        int256 debtShares = debtDiff.convertToShares(
            calculateBucketDebt(bucket, global, debtDiff > 0 ? NectraMathLib.Rounding.Down : NectraMathLib.Rounding.Up),
            bucket.totalDebtShares,
            debtDiff > 0 ? NectraMathLib.Rounding.Up : NectraMathLib.Rounding.Down
        );

        int256 globalDebtShares = debtDiff.convertToShares(
            global.debt, global.totalDebtShares, debtDiff > 0 ? NectraMathLib.Rounding.Up : NectraMathLib.Rounding.Down
        );

        globalDebtShares = globalDebtShares + bucket.globalDebtShares.toInt256() < 0
            ? -bucket.globalDebtShares.toInt256()
            : globalDebtShares;

        position.debtShares = NectraMathLib.saturatingAdd(position.debtShares, debtShares);
        position.collateral = NectraMathLib.saturatingAdd(position.collateral, collateralDiff);

        bucket.totalDebtShares = NectraMathLib.saturatingAdd(bucket.totalDebtShares, debtShares);
        bucket.globalDebtShares = NectraMathLib.saturatingAdd(bucket.globalDebtShares, globalDebtShares);
        bucket.collateral = NectraMathLib.saturatingAdd(bucket.collateral, collateralDiff);

        global.totalDebtShares = NectraMathLib.saturatingAdd(global.totalDebtShares, globalDebtShares);
        global.debt = NectraMathLib.saturatingAdd(global.debt, debtDiff);
    }

    /// @notice Migrates a position to a new bucket
    /// @dev Transfers position's debt shares and updates both source and destination buckets
    /// @param position The position to migrate
    /// @param dstBucket The destination bucket
    /// @param srcBucket The source bucket
    /// @param global The global state
    function migrateBucket(
        PositionState memory position,
        BucketState memory dstBucket,
        BucketState memory srcBucket,
        GlobalState memory global
    ) internal pure {
        uint256 globalDebtShares = position.debtShares.mulDivUp(srcBucket.globalDebtShares, srcBucket.totalDebtShares);
        uint256 debt = globalDebtShares.convertToAssets(global.debt, global.totalDebtShares, NectraMathLib.Rounding.Up);

        srcBucket.globalDebtShares = NectraMathLib.saturatingAdd(srcBucket.globalDebtShares, -int256(globalDebtShares));
        srcBucket.totalDebtShares = NectraMathLib.saturatingAdd(srcBucket.totalDebtShares, -int256(position.debtShares));

        uint256 debtShares = debt.convertToShares(
            calculateBucketDebt(dstBucket, global, NectraMathLib.Rounding.Down),
            dstBucket.totalDebtShares,
            NectraMathLib.Rounding.Up
        );

        dstBucket.globalDebtShares = NectraMathLib.saturatingAdd(dstBucket.globalDebtShares, int256(globalDebtShares));
        dstBucket.totalDebtShares = NectraMathLib.saturatingAdd(dstBucket.totalDebtShares, int256(debtShares));

        NectraLib.copy(
            position,
            NectraLib.PositionState({
                tokenId: position.tokenId,
                collateral: position.collateral,
                debtShares: debtShares,
                lastBucketAccumulatedLiquidatedCollateralPerShare: dstBucket.accumulatedLiquidatedCollateralPerShare,
                lastBucketAccumulatedRedeemedCollateralPerShare: dstBucket.accumulatedRedeemedCollateralPerShare,
                interestRate: dstBucket.interestRate,
                bucketEpoch: dstBucket.epoch,
                targetAccumulatedInterestPerBucketShare: dstBucket.accumulatedInterestPerShare
            })
        );
    }

    /// @notice Modifies a bucket's debt allocation in the global state
    /// @dev Updates both bucket and global state with debt changes
    /// @param bucket The bucket to modify
    /// @param global The global state
    /// @param debtDiff Change in debt amount
    function modifyBucket(BucketState memory bucket, GlobalState memory global, int256 debtDiff) internal pure {
        int256 globalDebtShares =
            debtDiff.convertToShares(global.debt, global.totalDebtShares, NectraMathLib.Rounding.Up);

        // update global state
        bucket.globalDebtShares = NectraMathLib.saturatingAdd(bucket.globalDebtShares, globalDebtShares);
        global.totalDebtShares = NectraMathLib.saturatingAdd(global.totalDebtShares, globalDebtShares);
        global.debt = NectraMathLib.saturatingAdd(global.debt, debtDiff);
    }

    /// @notice Calculates interest for a given amount and rate
    /// @dev Computes simple interest over a time period
    /// @param principal The principal amount
    /// @param interestRate The interest rate
    /// @param timeElapsed The time period
    /// @return The calculated interest
    function calculateInterest(uint256 principal, uint256 interestRate, uint256 timeElapsed)
        internal
        pure
        returns (uint256)
    {
        uint256 continuousRate = uint256(FixedPointMathLib.lnWad(int256(1 ether + interestRate)));
        uint256 interestRatio = uint256(FixedPointMathLib.expWad(int256(continuousRate * timeElapsed / 365 days)));

        // only return the interest portion
        return principal.mulWad(interestRatio - 1 ether);
    }

    /// @notice Copies bucket state from source to destination
    /// @dev Used for creating copies of bucket state
    /// @param dest The destination bucket state
    /// @param src The source bucket state
    function copy(NectraLib.BucketState memory dest, NectraLib.BucketState memory src) internal pure {
        dest.interestRate = src.interestRate;
        dest.collateral = src.collateral;
        dest.totalDebtShares = src.totalDebtShares;
        dest.globalDebtShares = src.globalDebtShares;
        dest.accumulatedLiquidatedCollateralPerShare = src.accumulatedLiquidatedCollateralPerShare;
        dest.accumulatedRedeemedCollateralPerShare = src.accumulatedRedeemedCollateralPerShare;
        dest.accumulatedInterestPerShare = src.accumulatedInterestPerShare;
        dest.lastGlobalAccumulatedLiquidatedCollateralPerShare = src.lastGlobalAccumulatedLiquidatedCollateralPerShare;
        dest.lastGlobalAccumulatedLiquidatedDebtPerShare = src.lastGlobalAccumulatedLiquidatedDebtPerShare;
        dest.lastUpdateTime = src.lastUpdateTime;
        dest.epoch = src.epoch;
    }

    /// @notice Copies position state from source to destination
    /// @dev Used for creating copies of position state
    /// @param dest The destination position state
    /// @param src The source position state
    function copy(NectraLib.PositionState memory dest, NectraLib.PositionState memory src) internal pure {
        dest.tokenId = src.tokenId;
        dest.collateral = src.collateral;
        dest.debtShares = src.debtShares;
        dest.bucketEpoch = src.bucketEpoch;
        dest.lastBucketAccumulatedLiquidatedCollateralPerShare = src.lastBucketAccumulatedLiquidatedCollateralPerShare;
        dest.lastBucketAccumulatedRedeemedCollateralPerShare = src.lastBucketAccumulatedRedeemedCollateralPerShare;
        dest.interestRate = src.interestRate;
        dest.targetAccumulatedInterestPerBucketShare = src.targetAccumulatedInterestPerBucketShare;
    }

    /// @notice Copies global state from source to destination
    /// @dev Used for creating copies of global state
    /// @param dest The destination global state
    /// @param src The source global state
    function copy(NectraLib.GlobalState memory dest, NectraLib.GlobalState memory src) internal pure {
        dest.debt = src.debt;
        dest.totalDebtShares = src.totalDebtShares;
        dest.accumulatedLiquidatedCollateralPerShare = src.accumulatedLiquidatedCollateralPerShare;
        dest.accumulatedLiquidatedDebtPerShare = src.accumulatedLiquidatedDebtPerShare;
        dest.unrealizedLiquidatedDebt = src.unrealizedLiquidatedDebt;
        dest.fees = src.fees;
    }
}
