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

    event Redemption(uint256 amount, uint256 collateralRedeemed, uint256 redemptionFee);

    /// @notice Redeems NUSD tokens for collateral
    /// @dev Calculates dynamic redemption fee and distributes collateral redemption across buckets
    /// @dev Redemption starts at the lowest bucket and iterates upward
    /// @param amount Amount of NUSD to redeem
    /// @param minAmountOut Minimum amount of collateral to receive
    /// @return collateralRedeemed Amount of collateral received
    function redeem(uint256 amount, uint256 minAmountOut) external returns (uint256) {
        require(amount > 0, InvalidAmount());

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

        // redeem from the redemption buffer first
        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();
        // will finalize the bucket state
        (uint256 amountRemaining, uint256 collateralRedeemed) = _redeemBufferBucket(
            globalState, 
            amount, 
            redemptionFeePercentage - treasuryFeePercentage, 
            collateralPrice, 
            config.MINIMUM_INTEREST_RATE,
            core._epochs[config.MINIMUM_INTEREST_RATE]
        );

        // if amount remaining is greater than 0, redeem from the buckets
        if (amountRemaining > 0) {
            (
                uint256 totalDebt, 
                uint256 numBuckets, 
                uint256[] memory bucketDebts, 
                NectraLib.BucketState[] memory buckets
            ) = getUpdatedBucketsAndDebt(globalState, collateralPrice, core, config);

            uint256 systemInterestRate = _systemInterestRate();

            // calculate the total debt of buckets below the system interest rate
            uint256 totalDebtBelowSystemInterestRate = 0;
            uint256 totalBucketsBelowSystemInterestRate = 0;
            for (uint256 i = 0; i < numBuckets; i++) {
                if (buckets[i].interestRate < systemInterestRate) {
                    totalDebtBelowSystemInterestRate += bucketDebts[i];
                    totalBucketsBelowSystemInterestRate++;
                }
            }

            // if the total debt below the system interest rate is greater than the amount remaining, redeem from the buckets
            if (totalDebtBelowSystemInterestRate >= amountRemaining) {
                // redeem buckets below system interest rate pro-rata
            // collateralRedeemed += _redeemFromBuckets(globalState, amountRemaining, redemptionFeePercentage - treasuryFeePercentage);
            collateralRedeemed += _redeemFromBuckets(globalState, amountRemaining, redemptionFeePercentage - treasuryFeePercentage, totalBucketsBelowSystemInterestRate);
            }
        }

        uint256 treasuryCollateralRedeemed = 0;
        if (treasuryFeePercentage > 0) {
            treasuryCollateralRedeemed = collateralRedeemed.divWad(
                1 ether - (redemptionFeePercentage - treasuryFeePercentage)
            ).mulWad(treasuryFeePercentage);
            collateralRedeemed -= treasuryCollateralRedeemed;
        }

        require(
            collateralRedeemed > 0 && collateralRedeemed >= minAmountOut,
            MinAmountOutNotMet(collateralRedeemed, minAmountOut)
        );

        _finalizeGlobal(globalState);

        NUSDToken(_systemConfig().NUSD_TOKEN_ADDRESS).burn(msg.sender, amount);
        // Transfer the collateral to the user
        address(msg.sender).safeTransferETH(collateralRedeemed);

        if (treasuryCollateralRedeemed > 0) {
            _systemConfig().FEE_RECIPIENT_ADDRESS.safeTransferETH(treasuryCollateralRedeemed);
        }

        emit Redemption(amount, collateralRedeemed, redemptionFeePercentage);

        return collateralRedeemed;
    }

    /// @notice Internal function to redeem collateral from buckets
    /// @dev Iterates through buckets to redeem collateral based on debt distribution
    /// @dev Starts at the lowest bucket with debt and ends when the redemption value is reached
    /// @param globalState Current global state of the system
    /// @param amount Amount of NUSD to redeem
    /// @param redemptionFee Fee percentage for redemption
    /// @return collateralRedeemed Total amount of collateral redeemed
    function _redeemFromBuckets(NectraLib.GlobalState memory globalState, uint256 amount, uint256 redemptionFee)
        internal
        returns (uint256 collateralRedeemed)
    {
        uint256 amountRemaining = amount;
        uint256 bucketId = 0;
        uint256 bitMaskIndex = 0;
        uint256 bitMask = _core()._bucketBitMasks[bitMaskIndex];
        uint256 interestRate = _systemConfig().MINIMUM_INTEREST_RATE;

        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

        while (true) {
            {
                uint256 shiftedMask = bitMask >> (bucketId % 256);

                if (shiftedMask == 0) {
                    bitMaskIndex++;
                    bitMask = _core()._bucketBitMasks[bitMaskIndex];
                    bucketId = bitMaskIndex * 256;
                    interestRate = _systemConfig().MINIMUM_INTEREST_RATE + bucketId * _systemConfig().INTEREST_RATE_INCREMENT;
                    continue;
                }

                {
                    bucketId += NectraMathLib.findFirstSet(shiftedMask);
                    interestRate = _systemConfig().MINIMUM_INTEREST_RATE + bucketId * _systemConfig().INTEREST_RATE_INCREMENT;
                }
            }

            require(interestRate <= _systemConfig().MAXIMUM_INTEREST_RATE, InsufficientCollateral());

            NectraLib.BucketState memory bucket =
                _loadAndUpdateBucketState(interestRate, _core()._epochs[interestRate], globalState);

            uint256 bucketDebt = NectraLib.calculateBucketDebt(bucket, globalState, NectraMathLib.Rounding.Down);

            if (
                bucket.collateral.mulWad(collateralPrice).divWad(_systemConfig().FULL_LIQUIDATION_RATIO + _systemConfig().OPEN_FEE_PERCENTAGE)
                    < bucketDebt
            ) {
                // if the bucket is likely insolvent, skip it but don't
                // remove it from the bit mask as if the
                // price changes it may become solvent again
                bucketId++;
            } else if (bucketDebt > 0) {
                // cap the amount of debt to burn to the bucket
                uint256 burnAmount = amountRemaining < bucketDebt ? amountRemaining : bucketDebt;

                NectraLib.modifyBucket(bucket, globalState, -int256(burnAmount));
                bucketDebt -= burnAmount;

                // round collateral redeemed down to not give rounding loss to redeemer
                uint256 collateral = burnAmount.divWad(collateralPrice);
                collateral -= collateral.mulWad(redemptionFee);

                // round redeemed collateral per share up to give rounding to the system
                bucket.accumulatedRedeemedCollateralPerShare += collateral.divWadUp(bucket.totalDebtShares);

                // update this in real-time to ensure the bucket doesn't go insolvent
                bucket.collateral = NectraMathLib.saturatingAdd(bucket.collateral, -int256(collateral));

                collateralRedeemed += collateral;
                amountRemaining -= burnAmount;
                _finalizeBucket(bucket);

                if (bucket.globalDebtShares == 0) {
                    _core()._epochs[interestRate]++;
                    // toggle the bit in the bit mask as we have fully redeemed from this bucket
                    bitMask &= ~(1 << (bucketId % 256));
                }
            }

            if (bucketId % 256 == 0xFF || amountRemaining == 0) {
                _core()._bucketBitMasks[bitMaskIndex] = bitMask;
                if (amountRemaining == 0) break;
            }
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

    function _redeemBufferBucket(
        NectraLib.GlobalState memory globalState, 
        uint256 redemptionAmount,
        uint256 redemptionFee,
        uint256 collateralPrice,
        uint256 interestRate,
        uint256 epoch
    ) internal returns (
        uint256 amountRemaining,
        uint256 collateralRedeemed
    ) {
        amountRemaining = redemptionAmount;

        // load the redemption buffer in the lowest bucket
        NectraLib.BucketState memory bucket =
            _loadAndUpdateBucketState(interestRate, epoch, globalState);

        uint256 bucketDebt = NectraLib.calculateBucketDebt(bucket, globalState, NectraMathLib.Rounding.Down);

        if (bucketDebt > 0) {
            // cap the amount of debt to burn to the bucket
            uint256 burnAmount = amountRemaining < bucketDebt ? amountRemaining : bucketDebt;

            NectraLib.modifyBucket(bucket, globalState, -int256(burnAmount));
            bucketDebt -= burnAmount;

            // round collateral redeemed down to not give rounding loss to redeemer
            uint256 collateral = burnAmount.divWad(collateralPrice);
            // leave redemption fee in the bucket, round up to give rounding to the bucket
            collateral -= collateral.mulWadUp(redemptionFee);

            // round redeemed collateral per share up to give rounding to the system
            bucket.accumulatedRedeemedCollateralPerShare += collateral.divWadUp(bucket.totalDebtShares);

            // update this in real-time to ensure the bucket doesn't go insolvent
            bucket.collateral = NectraMathLib.saturatingAdd(bucket.collateral, -int256(collateral));

            collateralRedeemed += collateral;
            amountRemaining -= burnAmount;
            _finalizeBucket(bucket);

            // if the bucket is fully redeemed, increment the epoch and clear the bit in the bit mask
            if (bucket.globalDebtShares == 0) {
                // TODO: maybe all of this should all be done in _finalizeBucket?
                _core()._epochs[interestRate]++;
                _storeBucketBitMask(interestRate, _bucketBitMask(interestRate) &= ~(1 << (_getBucketIndex(interestRate) % 256)));
                _storeNumActiveBuckets(_numActiveBuckets() -1);
            }
        }
    }

    function _redeemBucket(
        NectraLib.GlobalState memory globalState,
        NectraLib.BucketState memory bucket, 
        uint256 redemptionAmount,
        uint256 redemptionFee,
        uint256 collateralPrice,
        uint256 interestRate,
        uint256 bucketDebt
    ) internal returns (
        NectraLib.GlobalState memory,
        uint256 amountRemaining,
        uint256 collateralRedeemed
    ) {
        amountRemaining = redemptionAmount;

        if (bucketDebt > 0) {
            // cap the amount of debt to burn to the bucket
            uint256 burnAmount = amountRemaining < bucketDebt ? amountRemaining : bucketDebt;

            NectraLib.modifyBucket(bucket, globalState, -int256(burnAmount));
            bucketDebt -= burnAmount;

            // round collateral redeemed down to not give rounding loss to redeemer
            uint256 collateral = burnAmount.divWad(collateralPrice);
            // leave redemption fee in the bucket, round up to give rounding to the bucket
            collateral -= collateral.mulWadUp(redemptionFee);

            // round redeemed collateral per share up to give rounding to the system
            bucket.accumulatedRedeemedCollateralPerShare += collateral.divWadUp(bucket.totalDebtShares);

            // update this in real-time to ensure the bucket doesn't go insolvent
            bucket.collateral = NectraMathLib.saturatingAdd(bucket.collateral, -int256(collateral));

            collateralRedeemed += collateral;
            amountRemaining -= burnAmount;
            _finalizeBucket(bucket);

            // if the bucket is fully redeemed, increment the epoch and clear the bit in the bit mask
            if (bucket.globalDebtShares == 0) {
                // TODO: maybe all of this should all be done in _finalizeBucket?
                _core()._epochs[interestRate]++;
                _storeBucketBitMask(interestRate, _bucketBitMask(interestRate) &= ~(1 << (_getBucketIndex(interestRate) % 256)));
                _storeNumActiveBuckets(_numActiveBuckets() -1);
            }
        }

        // always pass back the updated global state
        return (globalState, amountRemaining, collateralRedeemed);
    }

    function getUpdatedBucketsAndDebt(
        NectraLib.GlobalState memory globalState, 
        uint256 collateralPrice,
        NectraCoreStorage.Layout storage core,
        NectraConfigStorage.Layout storage config
    ) internal view returns (
        uint256 _totalDebt, 
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

        // will reach system debt before max interest rate
        while ((_totalDebt < globalState.debt + globalState.unrealizedLiquidatedDebt) && interestRate <= config.MAXIMUM_INTEREST_RATE) {
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

            if (
                bucket.collateral.mulWad(collateralPrice).divWad(config.FULL_LIQUIDATION_RATIO + config.OPEN_FEE_PERCENTAGE)
                    < bucketDebt
            ) {
                // if the bucket is likely insolvent, skip it but don't
                // remove it from the bit mask as if the
                // price changes it may become solvent again
                bucketId++;
            } else if (bucketDebt > 0) {
                _totalDebt += bucketDebt;
                bucketDebts[numBuckets] = bucketDebt;
                buckets[numBuckets] = bucket;
                numBuckets++;
            }
        }
    }

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
    ) internal returns (uint256 collateralRedeemed) {
        uint256 amountRemaining = amount;
        uint256 bucketCollateralRedeemed = 0;
        uint256 bucketAmountRemaining = 0;
        
        for (uint256 i = rangeStart; i < rangeEnd; i++) {
            uint256 bucketDebt = bucketDebts[i];
            // round up to ensure the bucket can be fully redeemed
            uint256 bucketAmount = bucketDebt.mulWadUp(amount).divWadUp(totalDebtInRange);
     
            (globalState, bucketAmountRemaining, bucketCollateralRedeemed) = _redeemBucket(
                globalState, 
                buckets[i], 
                bucketAmount, 
                redemptionFee, 
                collateralPrice, 
                buckets[i].interestRate, 
                bucketDebt
            );
            
            collateralRedeemed += bucketCollateralRedeemed;
            amountRemaining -= bucketAmount;
        }
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
