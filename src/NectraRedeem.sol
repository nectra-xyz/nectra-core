// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraConfigStorage} from "src/storage/NectraConfigStorage.sol";
import {NectraCoreStorage} from "src/storage/NectraCoreStorage.sol";

/// @title NectraRedeem
/// @notice Handles the redemption of NUSD tokens for collateral
/// @dev Implements dynamic redemption fees and bucket-based redemption logic
abstract contract NectraRedeem is NectraBase {
    using NectraMathLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    /// @notice Storage for redemption fee calculation
    /// @param redemptionBuffer Accumulated amount of NUSD redeemed
    /// @param lastUpdateTimestamp Last time the redemption buffer was updated
    struct RedemptionFeeStorage {
        uint256 redemptionBuffer;
        uint256 lastUpdateTimestamp;
    }

    error MinAmountOutNotMet(uint256 amountOut, uint256 minAmountOut);
    error InsufficientBalance(uint256 amount, uint256 balance);

    /// @notice Emitted when NUSD is redeemed for collateral
    /// @param operator Address that redeemed the NUSD
    /// @param amount Amount of NUSD redeemed
    /// @param collateralRedeemed Amount of collateral received
    /// @param redemptionFee Redemption fee percentage
    event Redemption(address indexed operator, uint256 amount, uint256 collateralRedeemed, uint256 redemptionFee);

    /// @notice Emitted when a redemption fee is paid to fee recipient
    /// @dev Used for tracking redemption revenue
    /// @param amount Amount of collateral paid as fee
    event RedemptionFeePaid(uint256 amount);

    /// @notice Redeems NUSD tokens for collateral
    /// @dev Calculates dynamic redemption fee and distributes collateral redemption across buckets
    /// @dev Redemption starts at the buffer in the 0% bucket
    /// @dev Then it redeems the buckets below the system interest rate pro-rata
    /// @dev Finally it redeems the buckets the system interest rate and above pro-rata
    /// @param amount Amount of NUSD to redeem
    /// @param minAmountOut Minimum amount of collateral to receive
    /// @return collateralRedeemed Amount of collateral received
    function redeem(uint256 amount, uint256 minAmountOut) external returns (uint256) {
        require(amount > 0, InvalidAmount());
        uint256 balance = NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).balanceOf(msg.sender);
        require(amount <= balance, InsufficientBalance(amount, balance));

        _requireFlashMintUnlocked();
        _requireFlashBorrowUnlocked();
        
        NectraLib.GlobalState memory globalState = _loadGlobalState();
        NectraCoreStorage.Layout storage core = _core();
        NectraConfigStorage.Layout storage config = _systemConfig();

        uint256 redemptionFeePercentage = _calculateRedemptionFeeAndUpdateBuffer(globalState, amount);

        // cap the redemption fee to 100%
        if (redemptionFeePercentage > 1 ether) {
            redemptionFeePercentage = 1 ether;
        }

        uint256 treasuryFeePercentage = redemptionFeePercentage > _systemConfig().REDEMPTION_FEE_TREASURY_THRESHOLD
            ? redemptionFeePercentage - _systemConfig().REDEMPTION_FEE_TREASURY_THRESHOLD
            : 0;

        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();
        uint256 amountRemaining = amount;
        uint256 collateralRedeemed = 0;

        // check if there is a redemption buffer position and if it can be redeemed first
        if (core.redemptionBufferPositionId != 0) {
            // buffer bucket is always at 0% interest rate
            NectraLib.BucketState memory bucket =
                _loadAndUpdateBucketState(0, core._epochs[0], globalState);

            uint256 bucketDebt = NectraLib.calculateBucketDebt(bucket, globalState, NectraMathLib.Rounding.Down);

            if (bucketDebt > 0) {
                (amountRemaining, collateralRedeemed) = _redeemBucket(
                    globalState, 
                    bucket, 
                    amount, 
                    // force the redemption to leave 100% of the fee in the buffer position
                    redemptionFeePercentage, 
                    collateralPrice, 
                    0, 
                    bucketDebt);
            }
        }

        uint256 splitCollateralRedeemed = 0;

        // if amount remaining is greater than 0, redeem from the remaining buckets below the system interest rate
        if (amountRemaining > 0) {
            (
                uint256 numBuckets, 
                uint256[] memory bucketDebts, 
                NectraLib.BucketState[] memory buckets
            ) = _getUpdatedBucketsAndDebt(globalState, collateralPrice, core, config);

            uint256 systemInterestRate = _systemInterestRate();

            // calculate the total debt of buckets below the system interest rate
            uint256 totalDebtBelow = 0;
            uint256 numBucketsBelow = 0;
            for (uint256 i = 0; i < numBuckets; i++) {
                if (buckets[i].interestRate < systemInterestRate) {
                    totalDebtBelow += bucketDebts[i];
                    numBucketsBelow++;
                } else break;
            }

            // cap the amount to redeem below the system interest rate to the amount remaining
            uint256 amountToRedeemBelow = amountRemaining < totalDebtBelow ? amountRemaining : totalDebtBelow;
            amountRemaining -= amountToRedeemBelow;

            // if the total debt below the system interest rate is greater than the amount remaining, redeem from the buckets
            if (amountToRedeemBelow > 0) {
                // redeem buckets below system interest rate pro-rata
                // at most this should fully redeem all of these buckets with nothing remaining
                (splitCollateralRedeemed, ) = _redeemFromBucketRangeProRata(
                    globalState, 
                    amountToRedeemBelow, 
                    redemptionFeePercentage - treasuryFeePercentage, 
                    0, 
                    numBucketsBelow, 
                    totalDebtBelow, 
                    collateralPrice, 
                    bucketDebts, 
                    buckets
                );
            }

            // if amount remaining is greater than 0, redeem from the remaining buckets above the system interest rate
            if (amountRemaining > 0) {
                // calculate the total debt of buckets from the system interest rate onwards
                uint256 totalDebtFromSIR = 0;
                uint256 totalBucketsFromSIR = 0;
                for (uint256 i = numBucketsBelow; i < numBuckets; i++) {
                    if (buckets[i].interestRate >= systemInterestRate) {
                        totalDebtFromSIR += bucketDebts[i];
                        totalBucketsFromSIR++;
                    } else break;
                }

                // cap the amount to redeem from the system interest rate to the amount remaining
                uint256 amountToRedeemFromSIR = amountRemaining < totalDebtFromSIR ? amountRemaining : totalDebtFromSIR;
                amountRemaining -= amountToRedeemFromSIR;

                if (amountToRedeemFromSIR > 0) {
                    // redeem buckets above system interest rate pro-rata
                    // at most this should fully redeem the system
                    (uint256 collateralRedeemedFromSIR, ) = _redeemFromBucketRangeProRata(
                        globalState, 
                        amountToRedeemFromSIR, 
                        redemptionFeePercentage - treasuryFeePercentage, 
                        numBucketsBelow, 
                        numBuckets, 
                        totalDebtFromSIR, 
                        collateralPrice, 
                        bucketDebts, 
                        buckets
                    );

                    splitCollateralRedeemed += collateralRedeemedFromSIR;
                }
            }
        }

        uint256 treasuryCollateralRedeemed = 0;
        if (treasuryFeePercentage > 0) {
            treasuryCollateralRedeemed = splitCollateralRedeemed.divWad(
                1 ether - (redemptionFeePercentage - treasuryFeePercentage)
            ).mulWad(treasuryFeePercentage);
            splitCollateralRedeemed -= treasuryCollateralRedeemed;
        }

        collateralRedeemed += splitCollateralRedeemed;

        require(
            /*collateralRedeemed > 0 &&*/ collateralRedeemed >= minAmountOut,
            MinAmountOutNotMet(collateralRedeemed, minAmountOut)
        );

        _finalizeGlobal(globalState);

        NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).burn(msg.sender, amount);
        // Transfer the collateral to the user
        address(msg.sender).safeTransferETH(collateralRedeemed);

        if (treasuryCollateralRedeemed > 0) {
            _systemConfig().FEE_RECIPIENT_ADDRESS.safeTransferETH(treasuryCollateralRedeemed);
            emit RedemptionFeePaid(treasuryCollateralRedeemed);
        }

        emit Redemption(msg.sender,amount, collateralRedeemed, redemptionFeePercentage);

        return collateralRedeemed;
    }

    /// @notice Redeems a single bucket and updates the bucket state
    /// @param globalState Current global state of the system
    /// @param bucket Bucket to redeem
    /// @param redemptionAmount Amount of NUSD to redeem
    /// @param redemptionFee Redemption fee percentage to leave in the bucket
    /// @param collateralPrice Collateral price
    /// @param interestRate Interest rate of the bucket
    /// @param bucketDebt Debt of the bucket
    /// @return amountRemaining Amount of NUSD that was not redeemed
    /// @return collateralRedeemed Amount of collateral redeemed
    function _redeemBucket(
        NectraLib.GlobalState memory globalState,
        NectraLib.BucketState memory bucket, 
        uint256 redemptionAmount,
        uint256 redemptionFee,
        uint256 collateralPrice,
        uint256 interestRate,
        uint256 bucketDebt
    ) internal returns (
        uint256 amountRemaining,
        uint256 collateralRedeemed
    ) {
        if (bucketDebt > 0) {
            // cap the amount of debt to burn to the bucket
            uint256 burnAmount = redemptionAmount < bucketDebt ? redemptionAmount : bucketDebt;
   
            NectraLib.modifyBucket(bucket, globalState, -int256(burnAmount));
            bucketDebt -= burnAmount;

            // round collateral redeemed down to not give rounding loss to redeemer
            collateralRedeemed = burnAmount.divWad(collateralPrice);
            // leave redemption fee in the bucket, round up to give rounding to the bucket
            collateralRedeemed -= collateralRedeemed.mulWadUp(redemptionFee);

            // round redeemed collateral per share up to give rounding to the system
            bucket.accumulatedRedeemedCollateralPerShare += collateralRedeemed.divWadUp(bucket.totalDebtShares);

            // update this in real-time to ensure the bucket doesn't go insolvent
            bucket.collateral = NectraMathLib.saturatingAdd(bucket.collateral, -int256(collateralRedeemed));

            // should not underflow because burnAmount <= redemptionAmount
            amountRemaining = redemptionAmount - burnAmount;
            
            _finalizeBucket(bucket);

            // if the bucket is fully redeemed, increment the epoch
            if (bucket.globalDebtShares == 0) {
                _core()._epochs[interestRate]++;
            }
        }
    }

    /// @notice Gets the updated buckets and debt 
    /// @dev Skips buckets that are likely insolvent
    /// @param globalState Current global state of the system
    /// @param collateralPrice Collateral price
    /// @param core Current core state of the system
    /// @param config Current config state of the system
    /// @return numBuckets Number of buckets
    /// @return bucketDebts Debts of the buckets
    /// @return buckets Updated bucket states
    function _getUpdatedBucketsAndDebt(
        NectraLib.GlobalState memory globalState, 
        uint256 collateralPrice,
        NectraCoreStorage.Layout storage core,
        NectraConfigStorage.Layout storage config
    ) internal view returns (
        uint256 numBuckets,
        uint256[] memory bucketDebts,
        NectraLib.BucketState[] memory buckets
    ) {
        // initialize the arrays with the maximum number of active buckets
        bucketDebts = new uint256[](core.numActiveBuckets);
        buckets = new NectraLib.BucketState[](core.numActiveBuckets);

        uint256 bucketId = 0;
        uint256 bitMaskIndex = 0;
        uint256 bitMask = core._bucketBitMasks[bitMaskIndex];
        uint256 interestRate = config.MINIMUM_INTEREST_RATE;
        uint256 totalDebt = 0;

        // will reach system debt before max interest rate
        while ((totalDebt < globalState.debt + globalState.unrealizedLiquidatedDebt) && interestRate <= config.MAXIMUM_INTEREST_RATE) {
            {
                uint256 shiftedMask = bitMask >> (bucketId % 256);

                // if there are no more buckets in this set move to the next set
                if (shiftedMask == 0) {
                    bitMaskIndex++;
                    bitMask = core._bucketBitMasks[bitMaskIndex];
                    bucketId = bitMaskIndex * 256;
                    interestRate = config.MINIMUM_INTEREST_RATE + bucketId * config.INTEREST_RATE_INCREMENT;
                    continue;
                }

                // find the next bucket in the set that has debt
                {
                    bucketId += NectraMathLib.findFirstSet(shiftedMask);
                    interestRate = config.MINIMUM_INTEREST_RATE + bucketId * config.INTEREST_RATE_INCREMENT;
                }
            }

            NectraLib.BucketState memory bucket =
                _loadAndUpdateBucketState(interestRate, core._epochs[interestRate], globalState);

            uint256 bucketDebt = NectraLib.calculateBucketDebt(bucket, globalState, NectraMathLib.Rounding.Down);

            if (bucket.collateral.mulWad(collateralPrice).divWad(config.FULL_LIQUIDATION_RATIO) < bucketDebt) {
                // if the bucket is likely insolvent, skip it but don't
                // remove it from the bit mask as if the
                // price changes it may become solvent again
                bucketId++;
            } else if (bucketDebt > 0) {
                totalDebt += bucketDebt;
                bucketDebts[numBuckets] = bucketDebt;
                buckets[numBuckets] = bucket;
                numBuckets++;
                bucketId++;
            }
        }
    }

    /// @notice Redeems a range of buckets pro-rata
    /// @param globalState Current global state of the system
    /// @param amount Amount of NUSD to redeem
    /// @param redemptionFee Redemption fee percentage
    /// @param rangeStart Start index of the range
    /// @param rangeEnd End index of the range
    /// @param totalDebtInRange Total debt in the range
    /// @param collateralPrice Collateral price
    /// @param bucketDebts Debts of the buckets
    /// @param buckets Updated bucket states
    /// @return collateralRedeemed Amount of collateral redeemed
    /// @return amountRemaining Amount of NUSD that was not redeemed
    function _redeemFromBucketRangeProRata(
        NectraLib.GlobalState memory globalState, 
        uint256 amount, 
        uint256 redemptionFee, 
        uint256 rangeStart,
        uint256 rangeEnd,
        uint256 totalDebtInRange,
        uint256 collateralPrice,
        uint256[] memory bucketDebts,
        NectraLib.BucketState[] memory buckets
    ) internal returns (uint256 collateralRedeemed, uint256 amountRemaining) {
        uint256 bucketCollateralRedeemed = 0;
        uint256 bucketAmountRemaining = 0;
        uint256 totalRedeemed = 0;
        amountRemaining = amount;

        for (uint256 i = rangeStart; i < rangeEnd && amountRemaining > 0; i++) {
            uint256 bucketDebt = bucketDebts[i];

            // Proportional split, rounded down to avoid over-allocation
            uint256 bucketAmount = amount.mulWad(bucketDebt).divWad(totalDebtInRange);

            // Ensure we never allocate more than what remains
            if (bucketAmount > amountRemaining) bucketAmount = amountRemaining;

            // Allocate any tiny remainder to the last bucket in the range
            if (i + 1 == rangeEnd && bucketAmount < amountRemaining) {
                bucketAmount = amountRemaining;
            }

            // If proportional rounding yields zero but we still have a remainder,
            // redeem the remainder from the current (lowest-remaining) bucket
            if (bucketAmount == 0 && amountRemaining > 0) {
                bucketAmount = amountRemaining;
            }

            (bucketAmountRemaining, bucketCollateralRedeemed) = _redeemBucket(
                globalState,
                buckets[i],
                bucketAmount,
                redemptionFee,
                collateralPrice,
                buckets[i].interestRate,
                bucketDebt
            );

            collateralRedeemed += bucketCollateralRedeemed;

            // Only reduce by the actual redeemed amount to prevent underflow
            uint256 redeemedHere = bucketAmount - bucketAmountRemaining;
            if (redeemedHere > amountRemaining) {
                redeemedHere = amountRemaining;
            }
            amountRemaining -= redeemedHere;
            totalRedeemed += redeemedHere;
        }
    }

    /// @notice Calculates and updates the redemption fee buffer
    /// @param globalState Current global state of the system
    /// @param amount Amount of NUSD being redeemed
    /// @return redemptionFee Calculated redemption fee percentage
    function _calculateRedemptionFeeAndUpdateBuffer(NectraLib.GlobalState memory globalState, uint256 amount)
        internal
        returns (uint256)
    {
        RedemptionFeeStorage memory redemptionFeeData = RedemptionFeeStorage({
            redemptionBuffer: _core().redemptionBuffer,
            lastUpdateTimestamp: _core().redemptionLastUpdateTimestamp
        });
        uint256 fee = _calculateRedemptionFee(redemptionFeeData, globalState, amount);

        _core().redemptionBuffer = redemptionFeeData.redemptionBuffer;
        _core().redemptionLastUpdateTimestamp = redemptionFeeData.lastUpdateTimestamp;
        return fee;
    }

    /// @notice Calculates the redemption fee based on current state and redemption amount
    /// @param redemptionFeeData Current redemption fee storage state
    /// @param globalState Current global state of the system
    /// @param amount Amount of NUSD being redeemed
    /// @return redemptionFee Calculated redemption fee percentage
    function _calculateRedemptionFee(
        RedemptionFeeStorage memory redemptionFeeData,
        NectraLib.GlobalState memory globalState,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 elapsedTime = (block.timestamp - redemptionFeeData.lastUpdateTimestamp);
        if (elapsedTime >= _systemConfig().REDEMPTION_FEE_DECAY_PERIOD) {
            redemptionFeeData.redemptionBuffer = 0;
        } else {
            // decay redemption buffer
            redemptionFeeData.redemptionBuffer -=
                (redemptionFeeData.redemptionBuffer * elapsedTime) / _systemConfig().REDEMPTION_FEE_DECAY_PERIOD;
        }

        uint256 redemptionFee = _dynamicRedemptionFee(
            amount,
            redemptionFeeData.redemptionBuffer,
            globalState.debt,
            _systemConfig().REDEMPTION_DYNAMIC_FEE_SCALAR,
            _systemConfig().REDEMPTION_BASE_FEE
        );

        redemptionFeeData.redemptionBuffer += amount;
        redemptionFeeData.lastUpdateTimestamp = block.timestamp;

        return redemptionFee;
    }

    /// @notice Calculates the dynamic redemption fee using a logarithmic formula
    /// @param amount Amount of NUSD being redeemed
    /// @param buffer Current redemption buffer
    /// @param totalDebt Total system debt
    /// @param scalar Fee scaling factor
    /// @param baseRate Base fee rate
    /// @return fee Calculated redemption fee percentage
    function _dynamicRedemptionFee(uint256 amount, uint256 buffer, uint256 totalDebt, uint256 scalar, uint256 baseRate)
        internal
        pure
        returns (uint256)
    {
        // (R * x + k * ((H + T) * np.log(T / (T - x)) - x))/x
        if (amount == 0) return 0;
        if (amount >= totalDebt) return 1 ether;
        if (scalar == 0) return baseRate;

        uint256 fee = FixedPointMathLib.lnWad(totalDebt.divWad(totalDebt - amount).toInt256()).toUint256();
        fee = (buffer + totalDebt).mulWad(fee);
        fee = fee - amount;
        fee = fee.mulWad(scalar);
        fee = fee.divWad(amount) + baseRate;

        return fee;
    }

    /// @notice Returns the redemption fee percentage for a given amount to redeem
    /// @param amount Amount of NUSD to calculate fee for
    /// @return redemptionFee Calculated redemption fee percentage
    function getRedemptionFee(uint256 amount) external view returns (uint256) {
        NectraLib.GlobalState memory globalState = _loadGlobalState();
        RedemptionFeeStorage memory redemptionFeeData = RedemptionFeeStorage({
            redemptionBuffer: _core().redemptionBuffer,
            lastUpdateTimestamp: _core().redemptionLastUpdateTimestamp
        });

        return _calculateRedemptionFee(redemptionFeeData, globalState, amount);
    }
}
