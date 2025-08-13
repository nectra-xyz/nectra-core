// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

interface INectraFlashHandler {
    // ============ ERRORS ============
    error InvalidAsset(address asset);
    error InvalidPositionId(uint256 tokenId);
    error InvalidCBTCPrice(uint256 cBTCPrice, bool isStale);
    error InvalidAmount(uint256 amount, uint256 expectedAmount);
    error MaxDebtExceeded(uint256 swapAmountOut, uint256 maxDebt);
    error UnauthorizedCaller(address caller, address allowedCaller);
    error DesiredCollateralTooLow(uint256 desiredCollateral, uint256 msgValue);
    error IssuanceRatioExceeded(uint256 actualIssuanceRatio, uint256 maxIssuanceRatio);
    error InsufficientCollateralOut(uint256 actualCollateralOut, uint256 minCollateralOut);
    error InsufficientCollateralForSwap(uint256 availableCollateral, uint256 requiredCollateral); 

    // ============ FUNCTIONS ============
    
    /// @notice Get quote for closing a position
    /// @param tokenId The position to close
    /// @param limitSqrtPrice Price limit for the swap
    /// @return collateralOut Expected collateral output after closing
    /// @return collateralToSwap Amount of collateral that will be swapped to repay the loan and flash mint fee
    /// @return positionCollateral Amount of collateral in the position
    function quoteClosePosition(uint256 tokenId, uint160 limitSqrtPrice) external returns (
        uint256 collateralOut, 
        uint256 collateralToSwap,
        uint256 positionCollateral
    );

    /// @notice Create or increase the exposure of a leveraged position
    /// @param tokenId The position to modify
    /// @param desiredCollateral The desired final collateral in the position
    /// @param desiredInterestRate The desired interest rate
    /// @param maxDebt The maximum debt allowed in the position
    /// @param recipient The address to receive the position NFT when creating a new position
    /// @return tokenId The token ID of the position
    /// @dev If tokenId is 0, a new position is created. If tokenId is not 0, the position is modified.
    function increasePositionExposure(
        uint256 tokenId,
        uint256 desiredCollateral,
        uint256 desiredInterestRate,
        uint256 maxDebt,
        address recipient
    ) external payable returns (uint256);

    /// @notice Close a leveraged position by flash minting nUSD to repay debt and withdraw collateral
    /// @param tokenId The position to close
    /// @param minCollateralOut Minimum collateral to receive after closing (slippage protection)
    /// @param recipient Address to receive the withdrawn collateral
    /// @return collateralOut Amount of collateral sent to recipient
    function flashClosePosition(
        uint256 tokenId,
        uint256 minCollateralOut,
        address recipient
    ) external returns (uint256 collateralOut);

    /// @notice Callback function for flashBorrow
    /// @param asset The asset being borrowed
    /// @param amount The amount of the asset being borrowed
    /// @param premium The premium of the flash borrow
    /// @param initiator The address that initiated the flash borrow
    /// @param params The parameters for the flash borrow
    /// @return success Whether the operation was successful
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external payable returns (bool);

    /// @notice get cBTC price in USD
    function getCBTCPrice() external view returns (uint256);
} 