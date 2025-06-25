// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraBase} from "src/NectraBase.sol";

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

    RedemptionFeeStorage internal _redemptionFeeStorage;

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

        uint256 redemptionFeePercentage = _calculateRedemptionFeeAndUpdateBuffer(globalState, amount);

        // cap the redemption fee to 100%
        if (redemptionFeePercentage > 1 ether) {
            redemptionFeePercentage = 1 ether;
        }

        uint256 treasuryFeePercentage = redemptionFeePercentage > REDEMPTION_FEE_TREASURY_THRESHOLD
            ? redemptionFeePercentage - REDEMPTION_FEE_TREASURY_THRESHOLD
            : 0;

        uint256 collateralRedeemed =
            _redeemFromBuckets(globalState, amount, redemptionFeePercentage - treasuryFeePercentage);

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

        NUSDToken(NUSD_TOKEN_ADDRESS).burn(msg.sender, amount);
        // Transfer the collateral to the user
        address(msg.sender).safeTransferETH(collateralRedeemed);

        if (treasuryCollateralRedeemed > 0) {
            FEE_RECIPIENT_ADDRESS.safeTransferETH(treasuryCollateralRedeemed);
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
        uint256 bitMask = _bucketBitMasks[bitMaskIndex];
        uint256 interestRate = MINIMUM_INTEREST_RATE;

        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

        while (true) {
            {
                uint256 shiftedMask = bitMask >> (bucketId % 256);

                if (shiftedMask == 0) {
                    bitMaskIndex++;
                    bitMask = _bucketBitMasks[bitMaskIndex];
                    bucketId = bitMaskIndex * 256;
                    interestRate = MINIMUM_INTEREST_RATE + bucketId * INTEREST_RATE_INCREMENT;
                    continue;
                }

                {
                    bucketId += NectraMathLib.findFirstSet(shiftedMask);
                    interestRate = MINIMUM_INTEREST_RATE + bucketId * INTEREST_RATE_INCREMENT;
                }
            }

            require(interestRate <= MAXIMUM_INTEREST_RATE, InsufficientCollateral());

            NectraLib.BucketState memory bucket =
                _loadAndUpdateBucketState(interestRate, _epochs[interestRate], globalState);

            uint256 bucketDebt = NectraLib.calculateBucketDebt(bucket, globalState, NectraMathLib.Rounding.Down);

            if (bucket.collateral.mulWad(collateralPrice) < bucketDebt) {
                // if the bucket is insolvent, skip it but don't
                // remove it from the bit mask as if the
                // price changes it may become solvent again
                bucketId++;
            } else {
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
                    _epochs[interestRate]++;
                    // toggle the bit in the bit mask as we have fully redeemed from this bucket
                    bitMask &= ~(1 << (bucketId % 256));
                }

                if (bucketId % 256 == 0xFF || amountRemaining == 0) {
                    _bucketBitMasks[bitMaskIndex] = bitMask;
                    if (amountRemaining == 0) break;
                }
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
        RedemptionFeeStorage memory redemptionFeeData = _redemptionFeeStorage;
        uint256 fee = _calculateRedemptionFee(redemptionFeeData, globalState, amount);

        _redemptionFeeStorage = redemptionFeeData;
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
        if (elapsedTime >= REDEMPTION_FEE_DECAY_PERIOD) {
            redemptionFeeData.redemptionBuffer = 0;
        } else {
            // decay redemption buffer
            redemptionFeeData.redemptionBuffer -=
                (redemptionFeeData.redemptionBuffer * elapsedTime) / REDEMPTION_FEE_DECAY_PERIOD;
        }

        uint256 redemptionFee = _dynamicRedemptionFee(
            amount,
            redemptionFeeData.redemptionBuffer,
            globalState.debt,
            REDEMPTION_DYNAMIC_FEE_SCALAR,
            REDEMPTION_BASE_FEE
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
        RedemptionFeeStorage memory redemptionFeeData = _redemptionFeeStorage;

        return _calculateRedemptionFee(redemptionFeeData, globalState, amount);
    }
}
