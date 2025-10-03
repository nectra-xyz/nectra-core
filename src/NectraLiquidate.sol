// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {NectraLib} from "src/NectraLib.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NectraConfigStorage} from "src/storage/NectraConfigStorage.sol";

import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

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

    /// @notice Emitted when a liquidation fee is paid to fee recipient
    /// @dev Used for tracking liquidation revenue
    /// @param amount Amount of collateral paid as fee
    event LiquidationFeePaid(uint256 amount);

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

        NectraConfigStorage.Layout storage config = _systemConfig();

        uint256 positionDebt = NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up);
        uint256 collateralPrice = _collateralPriceWithCircuitBreaker();

        {
            uint256 cratio =
                positionDebt > 0 ? position.collateral.mulWad(collateralPrice).divWad(positionDebt) : type(uint256).max;

            require(cratio <= config.LIQUIDATION_RATIO, NotEligibleForLiquidation(cratio, config.LIQUIDATION_RATIO));
        }

        // calculate amount to fix the position
        uint256 amountToFix = (
            positionDebt.mulWadUp(config.ISSUANCE_RATIO) - position.collateral.mulWad(collateralPrice)
        ).divWadUp(config.ISSUANCE_RATIO - 1 ether);

        // calculate the amount of collateral to redeem
        uint256 collateralToRedeem = amountToFix.divWadUp(collateralPrice);

        uint256 penalty = amountToFix.mulWadUp(config.LIQUIDATION_PENALTY_PERCENTAGE);
        uint256 penaltyCollateral = penalty.divWadUp(collateralPrice).mulWadUp(config.ISSUANCE_RATIO);

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
        NUSDToken(config.NUSD_TOKEN_ADDRESS).burn(msg.sender, amountToFix + penalty);

        uint256 liquidatorReward = FixedPointMathLib.min(
            penaltyCollateral.mulWad(config.LIQUIDATOR_REWARD_PERCENTAGE),
            config.MAX_LIQUIDATOR_REWARD.divWad(collateralPrice)
        );

        address(msg.sender).safeTransferETH(collateralToRedeem + liquidatorReward);

        uint256 liquidationFee = penaltyCollateral - liquidatorReward;
        if (liquidationFee > 0) {
            config.FEE_RECIPIENT_ADDRESS.safeTransferETH(liquidationFee);
            emit LiquidationFeePaid(liquidationFee);
        }

        emit PositionLiquidated(
            tokenId,
            collateralToRedeem + liquidatorReward,
            amountToFix + penalty,
            liquidatorReward,
            liquidationFee,
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

        NectraConfigStorage.Layout storage config = _systemConfig();

        uint256 positionDebt = NectraLib.calculatePositionDebt(position, bucket, global, NectraMathLib.Rounding.Up);
        {
            uint256 collateralPrice = _collateralPriceWithCircuitBreaker();
            uint256 cratio =
                positionDebt > 0 ? position.collateral.mulWad(collateralPrice).divWad(positionDebt) : type(uint256).max;

            require(
                cratio <= config.FULL_LIQUIDATION_RATIO,
                NotEligibleForFullLiquidation(cratio, config.FULL_LIQUIDATION_RATIO)
            );
        }

        uint256 liquidatedDebt = positionDebt;
        uint256 liquidatedCollateral = position.collateral;

        // Remove the position from the bucket and global
        NectraLib.modifyPosition(position, bucket, global, -int256(liquidatedCollateral), -int256(liquidatedDebt));

        global.accumulatedLiquidatedDebtPerShare +=
            (liquidatedDebt + _systemConfig().FULL_LIQUIDATOR_FEE).divWad(global.totalDebtShares);
        global.accumulatedLiquidatedCollateralPerShare += liquidatedCollateral.divWad(global.totalDebtShares);
        global.unrealizedLiquidatedDebt += liquidatedDebt + config.FULL_LIQUIDATOR_FEE;

        position = NectraLib.PositionState({
            tokenId: tokenId,
            collateral: 0,
            debtShares: 0,
            lastBucketAccumulatedLiquidatedCollateralPerShare: bucket.accumulatedLiquidatedCollateralPerShare,
            lastBucketAccumulatedRedeemedCollateralPerShare: bucket.accumulatedRedeemedCollateralPerShare,
            interestRate: position.interestRate,
            bucketEpoch: position.bucketEpoch
        });

        _finalize(position, bucket, global);

        NUSDToken(config.NUSD_TOKEN_ADDRESS).mint(msg.sender, config.FULL_LIQUIDATOR_FEE);

        emit PositionFullyLiquidated(
            tokenId, liquidatedCollateral, liquidatedDebt, msg.sender, config.FULL_LIQUIDATOR_FEE
        );
    }
}
