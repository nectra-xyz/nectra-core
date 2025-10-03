// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISatsumaHandler {
    // ============ ERRORS ============

    error UnauthorizedDeposit(address caller, address allowedCaller);
    error TransferFailed(address token, address to, uint256 amount);

    // ============ QUOTE FUNCTIONS ============

    function getNUSDToWCBTCExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After);

    function getNUSDToWCBTCExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After);

    function getWCBTCToNUSDExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After);

    function getWCBTCToNUSDExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After);

    function getCBTCToNUSDExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After);

    function getCBTCToNUSDExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After);

    // ============ SWAP FUNCTIONS ============

    function swapNUSDToWCBTCExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice) external;

    function swapNUSDToWCBTCExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external;

    function swapNUSDToCBTCExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external;

    function swapWCBTCToNUSDExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice) external;

    function swapWCBTCToNUSDExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external;

    function swapCBTCToNUSDExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice)
        external
        payable;

    function swapCBTCToNUSDExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice)
        external
        payable;
}
