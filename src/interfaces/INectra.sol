// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {NectraLib} from "src/NectraLib.sol";
import {NectraBase} from "src/NectraBase.sol";

interface INectra {
    error CollateralMismatch();
    error FlashBorrowInProgress();
    error FlashBorrowNotRepaid();
    error FlashMintInProgress();
    error InsufficientCollateral();
    error InterestRateTooHigh(uint256 interestRate, uint256 maximumInterestRate);
    error InterestRateTooLow(uint256 interestRate, uint256 minimumInterestRate);
    error InvalidAmount();
    error InvalidCollateralPrice();
    error InvalidCollateralizationRatio(uint256 cratio, uint256 minCratio);
    error InvalidInterestRate();
    error MinAmountOutNotMet(uint256 amountOut, uint256 minAmountOut);
    error MinimumDebtNotMet(uint256 debt, uint256 minimumDebt);
    error MinimumDepositNotMet(uint256 deposit, uint256 minimumDeposit);
    error NotEligibleForFullLiquidation(uint256 cratio, uint256 fullLiquidationRatio);
    error NotEligibleForLiquidation(uint256 cratio, uint256 liquidationRatio);
    error NotOwnerNorApproved();
    error OperationFailed();

    event FlashBorrow(address indexed initiator, address indexed to, uint256 amount, uint256 fee);
    event FlashMint(address indexed initiator, address indexed to, uint256 amount, uint256 fee);
    event ModifyPosition(
        uint256 indexed tokenId,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 interestRate,
        address indexed operator
    );
    event PositionFullyLiquidated(
        uint256 indexed tokenId, uint256 collateral, uint256 debt, address indexed liquidator, uint256 liquidatorReward
    );
    event PositionLiquidated(
        uint256 indexed tokenId,
        uint256 collateralRedeemed,
        uint256 debtRepaid,
        uint256 liquidatorReward,
        uint256 liquidationFee,
        address indexed liquidator
    );

    function quoteModifyPosition(uint256 tokenId, int256 depositOrWithdraw, int256 borrowOrRepay, uint256 interestRate)
        external
        view
        returns (int256, int256);
    function modifyPosition(
        uint256 tokenId,
        int256 depositOrWithdraw,
        int256 borrowOrRepay,
        uint256 interestRate,
        bytes memory permit
    ) external payable returns (uint256, int256, int256, uint256, uint256);

    function updatePosition(uint256 tokenId) external;

    function flashMint(address to, uint256 amount, bytes memory data) external;
    function flashBorrow(address to, uint256 amount, bytes memory data) external;
    function repayFlashBorrow() external payable;

    function getRedemptionFee(uint256 amount) external view returns (uint256);
    function redeem(uint256 amount, uint256 minAmountOut) external returns (uint256);

    function liquidate(uint256 tokenId) external;
    function fullLiquidate(uint256 tokenId) external;

    function getPositionState(uint256 tokenId)
        external
        view
        returns (NectraLib.PositionState memory, NectraLib.BucketState memory, NectraLib.GlobalState memory);
    function getBucketState(uint256 interestRate)
        external
        view
        returns (NectraLib.BucketState memory, NectraLib.GlobalState memory);
    function getGlobalState() external view returns (NectraLib.GlobalState memory);
    function getConfig() external view returns (NectraBase.ConstructorArgs memory);
}
