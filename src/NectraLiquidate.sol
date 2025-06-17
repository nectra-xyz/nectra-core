// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraBase} from "src/NectraBase.sol";

/// @title NectraLiquidate
/// @notice Handles liquidation of undercollateralized positions
/// @dev Implements partial and full liquidation mechanisms with liquidator rewards
abstract contract NectraLiquidate is NectraBase {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    error NotEligibleForLiquidation(uint256 cratio, uint256 liquidationRatio);
    error NotEligibleForFullLiquidation(uint256 cratio, uint256 fullLiquidationRatio);

    /// @notice Emitted when a position is partially liquidated
    /// @param tokenId ID of the liquidated position
    /// @param collateralRedeemed Amount of collateral redeemed
    /// @param debtRepaid Amount of debt repaid
    /// @param liquidatorReward Amount of collateral given to liquidator
    /// @param liquidationFee Amount of collateral taken as fee
    /// @param liquidator Address that performed the liquidation
    event PositionLiquidated(
        uint256 indexed tokenId,
        uint256 collateralRedeemed,
        uint256 debtRepaid,
        uint256 liquidatorReward,
        uint256 liquidationFee,
        address indexed liquidator
    );

    /// @notice Emitted when a position is fully liquidated
    /// @param tokenId ID of the liquidated position
    /// @param collateral Total collateral in the position
    /// @param debt Total debt in the position
    /// @param liquidator Address that performed the liquidation
    /// @param liquidatorReward Fixed reward given to liquidator
    event PositionFullyLiquidated(
        uint256 indexed tokenId, uint256 collateral, uint256 debt, address indexed liquidator, uint256 liquidatorReward
    );

    /// @notice Partially liquidates an undercollateralized position
    /// @dev Repays debt and takes collateral as penalty, with a portion going to the liquidator
    /// @param tokenId ID of the position to liquidate
    function liquidate(uint256 tokenId) external {
        _requireFlashBorrowUnlocked();

        (
            NectraLib.PositionState memory position,
            NectraLib.BucketState memory bucket,
            NectraLib.GlobalState memory global
        ) = _loadAndUpdateState(tokenId);

        NectraLib.modifyPosition(
            position, bucket, global, 0, int256(NectraLib.calculateOutstandingFee(position, bucket))
        );

        uint256 positionDebt = NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up);
        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

        {
            uint256 cratio =
                positionDebt > 0 ? position.collateral.mulWad(collateralPrice).divWad(positionDebt) : type(uint256).max;

            require(cratio <= LIQUIDATION_RATIO, NotEligibleForLiquidation(cratio, LIQUIDATION_RATIO));
        }

        // calculate amount to fix the position
        uint256 amountToFix = (positionDebt.mulWadUp(ISSUANCE_RATIO) - position.collateral.mulWad(collateralPrice))
            .divWadUp(ISSUANCE_RATIO - 1 ether);

        // calculate the amount of collateral to redeem
        uint256 collateralToRedeem = amountToFix.divWadUp(collateralPrice);

        uint256 penalty = amountToFix.mulWadUp(LIQUIDATION_PENALTY_PERCENTAGE);
        uint256 penaltyCollateral = penalty.divWadUp(collateralPrice).mulWadUp(ISSUANCE_RATIO);

        require(collateralToRedeem + penaltyCollateral <= position.collateral, InsufficientCollateral());

        // update the position state
        NectraLib.modifyPosition({
            position: position,
            bucket: bucket,
            global: global,
            collateralDiff: -int256(collateralToRedeem + penaltyCollateral),
            debtDiff: -int256(amountToFix + penalty)
        });

        _finalize(position, bucket, global);

        // burn
        NUSDToken(NUSD_TOKEN_ADDRESS).burn(msg.sender, amountToFix + penalty);

        uint256 liquidatorReward = FixedPointMathLib.min(
            penaltyCollateral.mulWad(LIQUIDATOR_REWARD_PERCENTAGE), MAX_LIQUIDATOR_REWARD.divWad(collateralPrice)
        );

        address(msg.sender).safeTransferETH(collateralToRedeem + liquidatorReward);

        FEE_RECIPIENT_ADDRESS.safeTransferETH(penaltyCollateral - liquidatorReward);

        emit PositionLiquidated(
            tokenId,
            collateralToRedeem + liquidatorReward,
            amountToFix + penalty,
            liquidatorReward,
            penaltyCollateral - liquidatorReward,
            msg.sender
        );
    }

    /// @notice Fully liquidates a severely undercollateralized position
    /// @dev Closes the position and distributes collateral according to protocol rules
    /// @param tokenId ID of the position to fully liquidate
    function fullLiquidate(uint256 tokenId) external {
        _requireFlashBorrowUnlocked();
        _requireFlashMintUnlocked();

        (
            NectraLib.PositionState memory position,
            NectraLib.BucketState memory bucket,
            NectraLib.GlobalState memory global
        ) = _loadAndUpdateState(tokenId);

        uint256 realizedFee = NectraLib.calculateOutstandingFee(position, bucket);
        NectraLib.modifyPosition(position, bucket, global, 0, int256(realizedFee));
        global.fees += realizedFee;

        uint256 positionDebt = NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up);

        {
            uint256 collateralPrice = _collateralPriceWithCircuitBreaker();
            uint256 cratio =
                positionDebt > 0 ? position.collateral.mulWad(collateralPrice).divWad(positionDebt) : type(uint256).max;

            require(cratio <= FULL_LIQUIDATION_RATIO, NotEligibleForFullLiquidation(cratio, FULL_LIQUIDATION_RATIO));
        }

        uint256 liquidatedDebt = positionDebt;
        uint256 liquidatedCollateral = position.collateral;

        // Remove the position from the bucket and global
        NectraLib.modifyPosition(position, bucket, global, -int256(liquidatedCollateral), -int256(liquidatedDebt));

        global.accumulatedLiquidatedDebtPerShare +=
            (liquidatedDebt + FULL_LIQUIDATOR_FEE).divWad(global.totalDebtShares);
        global.accumulatedLiquidatedCollateralPerShare += liquidatedCollateral.divWad(global.totalDebtShares);
        global.unrealizedLiquidatedDebt += liquidatedDebt + FULL_LIQUIDATOR_FEE;

        position = NectraLib.PositionState({
            tokenId: tokenId,
            collateral: 0,
            debtShares: 0,
            lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            interestRate: position.interestRate,
            bucketEpoch: position.bucketEpoch,
            targetAccumulatedInterestPerBucketShare: bucket.accumulatedInterestPerShare
        });

        _finalize(position, bucket, global);

        NUSDToken(NUSD_TOKEN_ADDRESS).mint(msg.sender, FULL_LIQUIDATOR_FEE);

        emit PositionFullyLiquidated(tokenId, liquidatedCollateral, liquidatedDebt, msg.sender, FULL_LIQUIDATOR_FEE);
    }
}
