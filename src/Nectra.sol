// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraViews} from "src/NectraViews.sol";
import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraLiquidate} from "src/NectraLiquidate.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NectraFlash} from "src/NectraFlash.sol";

/// @title Nectra
/// @notice Core contract for managing collateralized debt positions
/// @dev Handles position creation, modification, and management with interest rate buckets
/// @dev Holds the deposited cBTC balance for the system
contract Nectra is NectraBase, NectraRedeem, NectraLiquidate, NectraFlash, NectraViews {
    using NectraMathLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    error MinimumDepositNotMet(uint256 deposit, uint256 minimumDeposit);
    error MinimumDebtNotMet(uint256 debt, uint256 minimumDebt);
    error InterestRateTooHigh(uint256 interestRate, uint256 maximumInterestRate);
    error InterestRateTooLow(uint256 interestRate, uint256 minimumInterestRate);
    error InvalidInterestRate();
    error InvalidCollateralizationRatio(uint256 cratio, uint256 minCratio);
    error CollateralMismatch();
    error NotOwnerNorApproved();

    /// @notice Emitted when a position is modified
    /// @param tokenId ID of the position being modified
    /// @param depositOrWithdraw Amount of collateral deposited (positive) or withdrawn (negative)
    /// @param borrowOrRepay Amount of debt borrowed (positive) or repaid (negative)
    /// @param interestRate New interest rate for the position
    /// @param operator Address that initiated the modification
    event ModifyPosition(
        uint256 indexed tokenId,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 indexed interestRate,
        address indexed operator
    );

    /// @param args Constructor parameters defined in NectraBase
    constructor(ConstructorArgs memory args) NectraBase(args) {}

    /// @notice Creates, modifies or closes a collateralized debt position
    /// @dev Handles interest rate change, debt issuance/repayment, and collateral deposit/withdraw
    /// @dev Requires appropriate permissions for the operation being performed if not position owner
    /// @param tokenId Existing position tokenId (0 for new position)
    /// @param depositOrWithdraw Amount of collateral to deposit (+) or withdraw (- or type(int256).min to close)
    /// @param borrowOrRepay Amount of nUSD to borrow (+) or repay (- or type(int256).min to close)
    /// @param interestRate Desired interest rate bucket (absolute value)
    /// @param permit Optional permit data for NUSD token approval
    /// @return tokenId The ID of the position being modified
    /// @return depositOrWithdraw Actual amount of collateral deposited or withdrawn
    /// @return borrowOrRepay Actual amount of nUSD borrowed or repaid
    /// @return collateral The total collateral in the position after modification
    /// @return effectiveDebt The total effective debt of the position after modification
    function modifyPosition(
        uint256 tokenId,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 interestRate,
        bytes calldata permit
    ) external payable returns (uint256, int256, int256, uint256, uint256) {
        NectraLib.GlobalState memory global;
        NectraLib.BucketState memory bucket;
        NectraLib.PositionState memory position;
        NectraLib.BucketState memory oldBucket;

        if (tokenId != 0) {
            (position, bucket, global) = _loadAndUpdateState(tokenId);

            uint256 permissionBitMask;

            if (interestRate != position.interestRate) {
                permissionBitMask |= 1 << uint256(NectraNFT.Permission.AdjustInterest);
            }
            if (borrowOrRepay < 0) {
                permissionBitMask |= 1 << uint256(NectraNFT.Permission.Repay);
            } else if (borrowOrRepay > 0) {
                permissionBitMask |= 1 << uint256(NectraNFT.Permission.Borrow);
            }
            if (depositOrWithdraw < 0) {
                permissionBitMask |= 1 << uint256(NectraNFT.Permission.Withdraw);
            } else if (depositOrWithdraw > 0) {
                permissionBitMask |= 1 << uint256(NectraNFT.Permission.Deposit);
            }

            require(
                NectraNFT(NECTRA_NFT_ADDRESS).authorized(tokenId, msg.sender, permissionBitMask), NotOwnerNorApproved()
            );
        } else {
            (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _epochs[interestRate]);
            position = NectraLib.PositionState({
                tokenId: NectraNFT(NECTRA_NFT_ADDRESS).mint(msg.sender),
                collateral: 0,
                debtShares: 0,
                lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                interestRate: interestRate,
                bucketEpoch: bucket.epoch,
                targetAccumulatedInterestPerBucketShare: 0
            });
        }

        uint256 effectiveDebt;
        (depositOrWithdraw, borrowOrRepay,, effectiveDebt) =
            _modifyPosition(position, bucket, oldBucket, global, depositOrWithdraw, borrowOrRepay, interestRate);

        require(
            depositOrWithdraw < 0 && msg.value == 0 || uint256(depositOrWithdraw) == msg.value, CollateralMismatch()
        );

        if (oldBucket.lastUpdateTime != 0) {
            _finalizeBucket(oldBucket, global);
        }
        _finalize(position, bucket, global);

        if (borrowOrRepay > 0) {
            // mint NUSD
            NUSDToken(NUSD_TOKEN_ADDRESS).mint(msg.sender, uint256(borrowOrRepay));
        } else if (borrowOrRepay < 0) {
            if (permit.length > 0) {
                // solhint-disable-next-line avoid-low-level-calls
                NUSD_TOKEN_ADDRESS.call(abi.encodePacked(NUSDToken.permit.selector, permit));
            }
            // burn NUSD
            NUSDToken(NUSD_TOKEN_ADDRESS).burn(msg.sender, uint256(-borrowOrRepay));
        }

        if (depositOrWithdraw < 0) {
            // transfer collateral to the contract
            address(msg.sender).safeTransferETH(uint256(-depositOrWithdraw));
        }

        emit ModifyPosition(
            position.tokenId,
            depositOrWithdraw,
            borrowOrRepay,
            interestRate,
            msg.sender
        );

        return (position.tokenId, depositOrWithdraw, borrowOrRepay, position.collateral, effectiveDebt);
    }

    /// @notice Simulates a position modification to preview the outcome
    /// @dev Returns the actual amounts that would be deposited/withdrawn and borrowed/repaid
    /// @param tokenId Existing position tokenId (0 for new position)
    /// @param depositOrWithdraw Amount of collateral to deposit (+) or withdraw (- or type(int256).min to close)
    /// @param borrowOrRepay Amount of nUSD to borrow (+) or repay (- or type(int256).min to close)
    /// @param interestRate Desired interest rate bucket (absolute value)
    /// @return depositOrWithdraw Actual amount of collateral that would be deposited or withdrawn
    /// @return borrowOrRepay Actual amount of nUSD that would be borrowed or repaid
    /// @return collateral The total collateral in the position after modification
    /// @return effectiveDebt The total effective debt of the position after modification
    function quoteModifyPosition(uint256 tokenId, int256 depositOrWithdraw, int256 borrowOrRepay, uint256 interestRate)
        external
        view
        returns (int256, int256, uint256, uint256)
    {
        NectraLib.GlobalState memory global;
        NectraLib.BucketState memory bucket;
        NectraLib.PositionState memory position;
        NectraLib.BucketState memory oldBucket;

        {
            if (tokenId != 0) {
                (position, bucket, global) = _loadAndUpdateState(tokenId);
            } else {
                (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _epochs[interestRate]);
                position = NectraLib.PositionState({
                    tokenId: 0,
                    collateral: 0,
                    debtShares: 0,
                    lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
                    lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
                    interestRate: interestRate,
                    bucketEpoch: bucket.epoch,
                    targetAccumulatedInterestPerBucketShare: 0
                });
            }
        }

        return _modifyPosition(position, bucket, oldBucket, global, depositOrWithdraw, borrowOrRepay, interestRate);
    }

    /// @notice Internal function to modify a position's state
    /// @dev Handles all position modifications including interest rate changes
    /// @param position Current position state
    /// @param bucket Current bucket state
    /// @param oldBucket Previous bucket state (if changing interest rates)
    /// @param global Current global state
    /// @param depositOrWithdraw Amount of collateral to deposit or withdraw
    /// @param borrowOrRepay Amount of nUSD to borrow or repay
    /// @param interestRate Desired interest rate bucket
    /// @return depositOrWithdraw Actual amount of collateral to deposit or withdraw
    /// @return borrowOrRepay Actual amount of nUSD to borrow or repay
    /// @return collateral Total collateral in the position after modification
    /// @return effectiveDebt Total effective debt in the position after modification
    function _modifyPosition(
        NectraLib.PositionState memory position,
        NectraLib.BucketState memory bucket,
        NectraLib.BucketState memory oldBucket,
        NectraLib.GlobalState memory global,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 interestRate
    ) internal view returns (int256, int256, uint256, uint256) {
        require(interestRate <= MAXIMUM_INTEREST_RATE, InterestRateTooHigh(interestRate, MAXIMUM_INTEREST_RATE));
        require(interestRate >= MINIMUM_INTEREST_RATE, InterestRateTooLow(interestRate, MINIMUM_INTEREST_RATE));
        require(interestRate % INTEREST_RATE_INCREMENT == 0, InvalidInterestRate());

        if (depositOrWithdraw < 0) {
            // Cannot withdraw collateral if a flash borrow is active
            _requireFlashBorrowUnlocked();
        }

        uint256 outstandingFees = NectraLib.calculateOutstandingFee(position, bucket);
        uint256 effectiveDebt =
            NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up) + outstandingFees;

        // Cap withdrawal to available collateral
        if (depositOrWithdraw + position.collateral.toInt256() < 0) {
            depositOrWithdraw = -int256(position.collateral);
        }

        // Cap repayment to current debt + fees
        if (borrowOrRepay + effectiveDebt.toInt256() < 0) {
            borrowOrRepay = -int256(effectiveDebt);
        }

        uint256 realizedFee = 0;

        // Fee realization logic
        if (interestRate < position.interestRate) {
            uint256 newFee = uint256(effectiveDebt.toInt256() + borrowOrRepay).mulWad(OPEN_FEE_PERCENTAGE);

            // Realize all outstanding fees when lowering interest rate
            realizedFee += outstandingFees;
            outstandingFees = newFee;
            effectiveDebt += newFee;
        } else if (borrowOrRepay <= 0) {
            // Repayment case
            if (effectiveDebt > 0 && borrowOrRepay + effectiveDebt.toInt256() > 0) {
                // Partial fee realization proportional to repayment
                realizedFee = outstandingFees.mulDiv(uint256(-borrowOrRepay), effectiveDebt);
            } else {
                // Realize all if closing position or if fully redeemed
                realizedFee = outstandingFees;
            }

            outstandingFees -= realizedFee;
        } else if (borrowOrRepay > 0) {
            // Borrowing case
            uint256 newFee = uint256(borrowOrRepay).mulWad(OPEN_FEE_PERCENTAGE);
            outstandingFees += newFee;
            effectiveDebt += newFee;
        }

        global.fees += realizedFee;

        NectraLib.modifyPosition({
            position: position,
            bucket: bucket,
            global: global,
            collateralDiff: depositOrWithdraw,
            debtDiff: borrowOrRepay + int256(realizedFee)
        });

        if (interestRate != position.interestRate && position.debtShares > 0) {
            NectraLib.copy(oldBucket, bucket);
            NectraLib.copy(bucket, _loadAndUpdateBucketState(interestRate, _epochs[interestRate], global));

            NectraLib.migrateBucket({position: position, srcBucket: oldBucket, dstBucket: bucket, global: global});
        }

        if (position.debtShares > 0) {
            position.targetAccumulatedInterestPerBucketShare =
                bucket.accumulatedInterestPerShare + outstandingFees.divWad(position.debtShares);
        } else {
            position.targetAccumulatedInterestPerBucketShare = bucket.accumulatedInterestPerShare;
        }

        effectiveDebt = uint256(int256(effectiveDebt) + borrowOrRepay);

        require(
            position.collateral >= MINIMUM_COLLATERAL || position.collateral == 0,
            MinimumDepositNotMet(position.collateral, MINIMUM_COLLATERAL)
        );
        require(
            effectiveDebt >= MINIMUM_BORROW || (effectiveDebt == 0 && position.collateral == 0),
            MinimumDebtNotMet(effectiveDebt, MINIMUM_BORROW)
        );

        // Can always improve c-ratio
        if (effectiveDebt > 0 && (borrowOrRepay > 0 || depositOrWithdraw < 0)) {
            uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

            // Check system collateralization ratio
            require(
                global.debt + global.unrealizedLiquidatedDebt == 0
                    || (address(this).balance).mulDiv(collateralPrice, global.debt + global.unrealizedLiquidatedDebt)
                        >= ISSUANCE_RATIO,
                InsufficientCollateral()
            );

            uint256 cratio = position.collateral.mulWad(collateralPrice).divWad(effectiveDebt);

            // Check position collateralization ratio
            require(cratio >= ISSUANCE_RATIO, InvalidCollateralizationRatio(cratio, ISSUANCE_RATIO));
        }

        return (depositOrWithdraw, borrowOrRepay, position.collateral, effectiveDebt);
    }

    /// @notice Updates an existing position's accounting and finalizes state
    /// @dev Updates accumulated interest and fees for a position
    /// @param tokenId The tokenId of the position to update
    function updatePosition(uint256 tokenId) external {
        (
            NectraLib.PositionState memory position,
            NectraLib.BucketState memory bucket,
            NectraLib.GlobalState memory global
        ) = _loadAndUpdateState(tokenId);

        _finalize(position, bucket, global);
    }

    /// @notice Updates the bucket state for a specific interest rate
    /// @dev Finalizes the bucket state and updates global state
    /// @param interestRate The interest rate bucket to update
    function updateBucket(uint256 interestRate) external {
        NectraLib.BucketState memory bucket;
        NectraLib.GlobalState memory global;

        (bucket, global) = _loadAndUpdateBucketAndGlobalState(interestRate, _epochs[interestRate]);

        _finalizeBucket(bucket, global);
        _finalizeGlobal(global);
    }
}
