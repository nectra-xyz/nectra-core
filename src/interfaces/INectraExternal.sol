// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface INectraExternal {
    struct PositionData {
        uint256 tokenId;
        uint256 collateral;
        uint256 debt;
        uint256 interestRate;
        uint256 outstandingFee;
    }

    function FEE_RECIPIENT_ADDRESS() external view returns (address);
    function FLASH_BORROW_FEE() external view returns (uint256);
    function FLASH_MINT_FEE() external view returns (uint256);
    function FULL_LIQUIDATION_RATIO() external view returns (uint256);
    function FULL_LIQUIDATOR_FEE() external view returns (uint256);
    function INTEREST_RATE_INCREMENT() external view returns (uint256);
    function ISSUANCE_RATIO() external view returns (uint256);
    function LIQUIDATION_PENALTY_PERCENTAGE() external view returns (uint256);
    function LIQUIDATION_RATIO() external view returns (uint256);
    function LIQUIDATOR_REWARD_PERCENTAGE() external view returns (uint256);
    function MAXIMUM_INTEREST_RATE() external view returns (uint256);
    function MAX_LIQUIDATOR_REWARD() external view returns (uint256);
    function MINIMUM_BORROW() external view returns (uint256);
    function MINIMUM_COLLATERAL() external view returns (uint256);
    function MINIMUM_INTEREST_RATE() external view returns (uint256);
    function NECTRA_NFT_ADDRESS() external view returns (address);
    function NUSD_TOKEN_ADDRESS() external view returns (address);
    function OPEN_FEE_PERCENTAGE() external view returns (uint256);
    function ORACLE_ADDRESS() external view returns (address);
    function REDEMPTION_BASE_FEE() external view returns (uint256);
    function REDEMPTION_DYNAMIC_FEE_SCALAR() external view returns (uint256);
    function REDEMPTION_FEE_DECAY_PERIOD() external view returns (uint256);
    function REDEMPTION_FEE_TREASURY_THRESHOLD() external view returns (uint256);
    function calculateInterest(uint256 principal, uint256 interestRate, uint256 timeElapsed)
        external
        pure
        returns (uint256);
    function canLiquidate(uint256 tokenId) external view returns (bool);
    function canLiquidateFull(uint256 tokenId) external view returns (bool);
    function getBucketDebt(uint256 interestRate) external view returns (uint256);
    function getGlobalDebt() external view returns (uint256);
    function getPosition(uint256 tokenId) external view returns (uint256 collateral, uint256 debt);
    function getPositionCollateral(uint256 tokenId) external view returns (uint256);
    function getPositionDebt(uint256 tokenId) external view returns (uint256);
    function getPositionFullLiquidationPrice(uint256 tokenId) external view returns (uint256);
    function getPositionLiquidationPrice(uint256 tokenId) external view returns (uint256);
    function getPositionOutstandingFee(uint256 tokenId) external view returns (uint256);
    function getPositionsForAddress(address owner) external view returns (PositionData[] memory);
}
