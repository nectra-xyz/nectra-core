// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraMathLib} from "src/NectraMathLib.sol";
import {NectraBase} from "src/NectraBase.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

import {INectra} from "src/interfaces/INectra.sol";
import {INectraNFT} from "src/interfaces/INectraNFT.sol";

contract NectraExternal {
    using NectraMathLib for uint256;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    struct PositionData {
        uint256 tokenId;
        uint256 collateral;
        uint256 debt;
        uint256 interestRate;
        uint256 outstandingFee;
    }

    INectra internal immutable nectra;
    INectraNFT internal immutable nectraNFT;

    uint256 public LIQUIDATION_RATIO;
    uint256 public FULL_LIQUIDATION_RATIO;
    uint256 public ISSUANCE_RATIO;
    uint256 public LIQUIDATION_PENALTY_PERCENTAGE;
    uint256 public LIQUIDATOR_REWARD_PERCENTAGE;
    uint256 public MAX_LIQUIDATOR_REWARD;
    uint256 public FULL_LIQUIDATOR_FEE;
    uint256 public REDEMPTION_FEE_DECAY_PERIOD;
    uint256 public REDEMPTION_BASE_FEE;
    uint256 public REDEMPTION_DYNAMIC_FEE_SCALAR;
    uint256 public REDEMPTION_FEE_TREASURY_THRESHOLD;
    uint256 public MAXIMUM_INTEREST_RATE;
    uint256 public MINIMUM_INTEREST_RATE;
    uint256 public INTEREST_RATE_INCREMENT;
    uint256 public OPEN_FEE_PERCENTAGE;
    uint256 public MINIMUM_COLLATERAL;
    uint256 public MINIMUM_BORROW;
    uint256 public FLASH_MINT_FEE;
    uint256 public FLASH_BORROW_FEE;
    address public NECTRA_NFT_ADDRESS;
    address public NUSD_TOKEN_ADDRESS;
    address public ORACLE_ADDRESS;
    address public FEE_RECIPIENT_ADDRESS;

    constructor(address _nectra, address _nectraNFT) {
        nectra = INectra(_nectra);
        nectraNFT = INectraNFT(_nectraNFT);

        NectraBase.ConstructorArgs memory cargs = nectra.getConfig();

        NECTRA_NFT_ADDRESS = cargs.nectraNFTAddress;
        NUSD_TOKEN_ADDRESS = cargs.nusdTokenAddress;
        ORACLE_ADDRESS = cargs.oracleAddress;
        FEE_RECIPIENT_ADDRESS = cargs.feeRecipientAddress;
        MINIMUM_COLLATERAL = cargs.minimumCollateral;
        MINIMUM_BORROW = cargs.minimumDebt;
        MAXIMUM_INTEREST_RATE = cargs.maximumInterestRate;
        MINIMUM_INTEREST_RATE = cargs.minimumInterestRate;
        INTEREST_RATE_INCREMENT = cargs.interestRateIncrement;
        LIQUIDATION_RATIO = cargs.liquidationRatio;
        FULL_LIQUIDATION_RATIO = cargs.fullLiquidationRatio;
        ISSUANCE_RATIO = cargs.issuanceRatio;
        OPEN_FEE_PERCENTAGE = cargs.openFeePercentage;
        LIQUIDATION_PENALTY_PERCENTAGE = cargs.liquidationPenaltyPercentage;
        LIQUIDATOR_REWARD_PERCENTAGE = cargs.liquidatorRewardPercentage;
        MAX_LIQUIDATOR_REWARD = cargs.maximumLiquidatorReward;
        FULL_LIQUIDATOR_FEE = cargs.fullLiquidationFee;
        REDEMPTION_FEE_DECAY_PERIOD = cargs.redemptionFeeDecayPeriod;
        REDEMPTION_BASE_FEE = cargs.redemptionBaseFee;
        REDEMPTION_DYNAMIC_FEE_SCALAR = cargs.redemptionDynamicFeeScalar;
        REDEMPTION_FEE_TREASURY_THRESHOLD = cargs.redemptionFeeTreasuryThreshold;
        FLASH_MINT_FEE = cargs.flashMintFee;
        FLASH_BORROW_FEE = cargs.flashBorrowFee;
    }

    /// @notice Gets the total debt of a position including outstanding fees
    /// @dev Updates position state before calculation
    /// @param tokenId ID of the position to query
    /// @return Position debt including outstanding fees
    function getPositionDebt(uint256 tokenId) public view returns (uint256) {
        (
            NectraLib.PositionState memory positionState,
            NectraLib.BucketState memory bucketState,
            NectraLib.GlobalState memory globalState
        ) = nectra.getPositionState(tokenId);

        return NectraLib.calculatePositionDebt(positionState, bucketState, globalState, NectraMathLib.Rounding.Up)
            + NectraLib.calculateOutstandingFee(positionState, bucketState);
    }

    /// @notice Gets the collateral amount of a position
    /// @dev Updates position state before returning
    /// @param tokenId ID of the position to query
    /// @return Amount of collateral in the position
    function getPositionCollateral(uint256 tokenId) public view returns (uint256) {
        (NectraLib.PositionState memory positionState,,) = nectra.getPositionState(tokenId);

        return positionState.collateral;
    }

    /// @notice Gets both collateral and debt of a position
    /// @dev Updates position state before calculation
    /// @param tokenId ID of the position to query
    /// @return collateral Amount of collateral in the position
    /// @return debt Position debt including outstanding fees
    function getPosition(uint256 tokenId) public view returns (uint256 collateral, uint256 debt) {
        (
            NectraLib.PositionState memory positionState,
            NectraLib.BucketState memory bucketState,
            NectraLib.GlobalState memory globalState
        ) = nectra.getPositionState(tokenId);

        return (
            positionState.collateral,
            NectraLib.calculatePositionDebt(positionState, bucketState, globalState, NectraMathLib.Rounding.Up)
                + NectraLib.calculateOutstandingFee(positionState, bucketState)
        );
    }

    /// @notice Gets the outstanding fee for a position
    /// @dev Updates position state before calculation
    /// @param tokenId ID of the position to query
    /// @return Amount of outstanding fees
    function getPositionOutstandingFee(uint256 tokenId) public view returns (uint256) {
        (NectraLib.PositionState memory positionState, NectraLib.BucketState memory bucketState,) =
            nectra.getPositionState(tokenId);

        return NectraLib.calculateOutstandingFee(positionState, bucketState);
    }

    /// @notice Gets the liquidation price for a position
    /// @dev Updates position state before calculation
    /// @param tokenId ID of the position to query
    /// @return Price where position becomes at risk of liquidatation
    function getPositionLiquidationPrice(uint256 tokenId) public view returns (uint256) {
        (uint256 collateral, uint256 debt) = getPosition(tokenId);

        return LIQUIDATION_RATIO.mulWad(debt).divWad(collateral);
    }

    /// @notice Gets the full liquidation price for a position
    /// @dev Updates position state before calculation
    /// @param tokenId ID of the position to query
    /// @return Price where position becomes at risk of full liquidation
    function getPositionFullLiquidationPrice(uint256 tokenId) public view returns (uint256) {
        (uint256 collateral, uint256 debt) = getPosition(tokenId);

        return FULL_LIQUIDATION_RATIO.mulWad(debt).divWad(collateral);
    }

    /// @notice Returns all positions owned by a specific address
    /// @dev Queries the NFT contract for all token IDs owned by the address and retrieves their position data
    /// @param owner The address to query positions for
    /// @return Array of PositionData structs containing the position information for each owned position
    function getPositionsForAddress(address owner) public view returns (PositionData[] memory) {
        uint256[] memory tokenIds = nectraNFT.getTokenIdsForAddress(owner);
        PositionData[] memory positions = new PositionData[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            (NectraLib.PositionState memory position,,) = nectra.getPositionState(tokenIds[i]);
            uint256 debt = getPositionDebt(tokenIds[i]);
            uint256 outstandingFee = getPositionOutstandingFee(tokenIds[i]);

            positions[i] = PositionData({
                tokenId: tokenIds[i],
                collateral: position.collateral,
                debt: debt,
                interestRate: position.interestRate,
                outstandingFee: outstandingFee
            });
        }
        return positions;
    }

    /// @notice Gets the total debt in a bucket
    /// @dev Updates bucket state before calculation
    /// @param interestRate Interest rate of the bucket to query
    /// @return Total debt in the bucket
    function getBucketDebt(uint256 interestRate) external view returns (uint256) {
        (NectraLib.BucketState memory bucketState, NectraLib.GlobalState memory globalState) =
            nectra.getBucketState(interestRate);

        return bucketState.globalDebtShares.convertToAssets(
            globalState.debt, globalState.totalDebtShares, NectraMathLib.Rounding.Up
        );
    }

    /// @notice Gets the total debt in the system including unrealized liquidated debt
    /// @return Total system debt
    function getGlobalDebt() external view returns (uint256) {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();
        return globalState.debt + globalState.unrealizedLiquidatedDebt;
    }

    /// @notice Calculates interest for a given principal and rate
    /// @param principal The principal amount
    /// @param interestRate The interest rate
    /// @param timeElapsed The time period
    /// @return The calculated interest
    function calculateInterest(uint256 principal, uint256 interestRate, uint256 timeElapsed)
        external
        pure
        returns (uint256)
    {
        return NectraLib.calculateInterest(principal, interestRate, timeElapsed);
    }

    /// @notice Checks if a position can be liquidated
    /// @dev Considers current collateral price and position state
    /// @param tokenId ID of the position to check
    /// @return True if position can be liquidated
    function canLiquidate(uint256 tokenId) external view returns (bool) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(ORACLE_ADDRESS).getLatestPrice();
        if (isStale) {
            return false;
        }

        (
            NectraLib.PositionState memory positionState,
            NectraLib.BucketState memory bucketState,
            NectraLib.GlobalState memory globalState
        ) = nectra.getPositionState(tokenId);

        uint256 debt =
            NectraLib.calculatePositionDebt(positionState, bucketState, globalState, NectraMathLib.Rounding.Up);
        uint256 closingFee = NectraLib.calculateOutstandingFee(positionState, bucketState);
        uint256 cratio = positionState.collateral.mulWad(collateralPrice).divWad(debt + closingFee);

        return cratio <= LIQUIDATION_RATIO;
    }

    /// @notice Checks if a position can be fully liquidated
    /// @dev Considers current collateral price and position state
    /// @param tokenId ID of the position to check
    /// @return True if position can be fully liquidated
    function canLiquidateFull(uint256 tokenId) external view returns (bool) {
        (uint256 collateralPrice, bool isStale) = OracleAggregator(ORACLE_ADDRESS).getLatestPrice();
        if (isStale) {
            return false;
        }

        (
            NectraLib.PositionState memory positionState,
            NectraLib.BucketState memory bucketState,
            NectraLib.GlobalState memory globalState
        ) = nectra.getPositionState(tokenId);

        uint256 debt =
            NectraLib.calculatePositionDebt(positionState, bucketState, globalState, NectraMathLib.Rounding.Up);
        uint256 closingFee = NectraLib.calculateOutstandingFee(positionState, bucketState);
        uint256 cratio = positionState.collateral.mulWad(collateralPrice).divWad(debt + closingFee);

        return cratio <= FULL_LIQUIDATION_RATIO;
    }
}
