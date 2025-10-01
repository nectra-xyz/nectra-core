// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISwapRouter} from "src/interfaces/Satsuma/ISwapRouter.sol";
import {IQuoterV2} from "src/interfaces/Satsuma/IQuoterV2.sol";
import {IWCBTC} from "src/interfaces/IWCBTC.sol";
import {SafeTransferLib} from "src/lib/SafeTransferLib.sol";
// use OZ IERC20 instead of our own for safeTransfer functionality
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SatsumaHandler {
    using SafeTransferLib for address;
    using SafeERC20 for IERC20;

    ISwapRouter public swapRouter;
    IQuoterV2 public quoter;
    IERC20 public nUSD;
    IWCBTC public WCBTC;

    error UnauthorizedDeposit(address caller, address allowedCaller);
    error TransferFailed(address token, address to, uint256 amount);

    constructor(address _swapRouter, address _quoter, address _nUSD, address _WCBTC) {
        swapRouter = ISwapRouter(_swapRouter);
        quoter = IQuoterV2(_quoter);
        nUSD = IERC20(_nUSD);
        WCBTC = IWCBTC(_WCBTC);
    }

    // ============ INTERNAL HELPER FUNCTIONS ============
    /// @notice Internal function to get the WCBTC token
    /// @return The WCBTC token
    function _WCBTCToken() internal view returns (IERC20) {
        return IERC20(address(WCBTC));
    }

    /// @notice Internal function to get exact input quote
    function _getExactInputQuote(address tokenIn, address tokenOut, uint256 amountIn, uint160 limitSqrtPrice)
        internal
        returns (uint256 amountOut, uint160 sqrtPriceX96After)
    {
        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            deployer: address(0),
            amountIn: amountIn,
            limitSqrtPrice: limitSqrtPrice
        });

        (amountOut,, sqrtPriceX96After,,,) = quoter.quoteExactInputSingle(params);
    }

    /// @notice Internal function to get exact output quote
    function _getExactOutputQuote(address tokenIn, address tokenOut, uint256 amountOut, uint160 limitSqrtPrice)
        internal
        returns (uint256 amountIn, uint160 sqrtPriceX96After)
    {
        IQuoterV2.QuoteExactOutputSingleParams memory params = IQuoterV2.QuoteExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            deployer: address(0),
            amount: amountOut,
            limitSqrtPrice: limitSqrtPrice
        });

        (, amountIn, sqrtPriceX96After,,,) = quoter.quoteExactOutputSingle(params);
    }

    /// @notice Internal function to execute exact input swap
    function _executeExactInputSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 limitSqrtPrice
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).approve(address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            deployer: address(0),
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            limitSqrtPrice: limitSqrtPrice
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    /// @notice Internal function to execute exact output swap
    function _executeExactOutputSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 limitSqrtPrice
    ) internal returns (uint256 amountIn) {
        IERC20(tokenIn).approve(address(swapRouter), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            deployer: address(0),
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            limitSqrtPrice: limitSqrtPrice
        });

        amountIn = swapRouter.exactOutputSingle(params);

        // Clear unspent allowance
        if (amountIn < amountInMaximum) {
            IERC20(tokenIn).approve(address(swapRouter), 0);
        }
    }

    /// @notice Internal function to transfer remaining token balances to msg.sender
    function _transferRemainingBalances() internal {
        uint256 nusdBalAfter = nUSD.balanceOf(address(this));
        if (nusdBalAfter > 0) {
            nUSD.safeTransfer(msg.sender, nusdBalAfter);
        }

        uint256 wcbTcBalAfter = _WCBTCToken().balanceOf(address(this));
        if (wcbTcBalAfter > 0) {
            _WCBTCToken().safeTransfer(msg.sender, wcbTcBalAfter);
        }
    }

    /// @notice Internal function to transfer remaining balances, converting WCBTC to cBTC
    function _transferRemainingBalancesWithCBTCConversion() internal {
        uint256 nusdBalAfter = nUSD.balanceOf(address(this));
        if (nusdBalAfter > 0) {
            nUSD.safeTransfer(msg.sender, nusdBalAfter);
        }

        uint256 wcbTcBalAfter = _WCBTCToken().balanceOf(address(this));
        if (wcbTcBalAfter > 0) {
            WCBTC.withdraw(wcbTcBalAfter);
            msg.sender.safeTransferETH(wcbTcBalAfter);
        }
    }

    // ============ QUOTE FUNCTIONS ============

    function getNUSDToWCBTCExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After)
    {
        return _getExactInputQuote(address(nUSD), address(WCBTC), amountIn, limitSqrtPrice);
    }

    function getNUSDToWCBTCExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After)
    {
        return _getExactOutputQuote(address(nUSD), address(WCBTC), amountOut, limitSqrtPrice);
    }

    function getWCBTCToNUSDExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        public
        returns (uint256 amountOut, uint160 sqrtPriceX96After)
    {
        return _getExactInputQuote(address(WCBTC), address(nUSD), amountIn, limitSqrtPrice);
    }

    function getWCBTCToNUSDExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        public
        returns (uint256 amountIn, uint160 sqrtPriceX96After)
    {
        return _getExactOutputQuote(address(WCBTC), address(nUSD), amountOut, limitSqrtPrice);
    }

    function getCBTCToNUSDExactInputQuote(uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After)
    {
        // Same as WCBTC quote since we just wrap first
        return getWCBTCToNUSDExactInputQuote(amountIn, limitSqrtPrice);
    }

    function getCBTCToNUSDExactOutputQuote(uint256 amountOut, uint160 limitSqrtPrice)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After)
    {
        // Same as WCBTC quote since we just wrap first
        return getWCBTCToNUSDExactOutputQuote(amountOut, limitSqrtPrice);
    }

    // ============ NUSD -> WCBTC/cBTC SWAP FUNCTIONS ============

    function swapNUSDToWCBTCExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice) external {
        nUSD.safeTransferFrom(msg.sender, address(this), amountIn);

        _executeExactInputSwap(address(nUSD), address(WCBTC), amountIn, amountOutMinimum, limitSqrtPrice);
        _transferRemainingBalances();
    }

    function swapNUSDToWCBTCExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external {
        nUSD.safeTransferFrom(msg.sender, address(this), amountInMaximum);

        _executeExactOutputSwap(address(nUSD), address(WCBTC), amountOut, amountInMaximum, limitSqrtPrice);
        _transferRemainingBalances();
    }

    function swapNUSDToCBTCExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external {
        nUSD.safeTransferFrom(msg.sender, address(this), amountInMaximum);

        _executeExactOutputSwap(address(nUSD), address(WCBTC), amountOut, amountInMaximum, limitSqrtPrice);
        _transferRemainingBalancesWithCBTCConversion();
    }

    // ============ WCBTC/cBTC -> NUSD SWAP FUNCTIONS ============

    function swapWCBTCToNUSDExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice) external {
        _WCBTCToken().safeTransferFrom(msg.sender, address(this), amountIn);

        _executeExactInputSwap(address(WCBTC), address(nUSD), amountIn, amountOutMinimum, limitSqrtPrice);
        _transferRemainingBalances();
    }

    function swapWCBTCToNUSDExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice) external {
        _WCBTCToken().safeTransferFrom(msg.sender, address(this), amountInMaximum);

        _executeExactOutputSwap(address(WCBTC), address(nUSD), amountOut, amountInMaximum, limitSqrtPrice);
        _transferRemainingBalances();
    }

    function swapCBTCToNUSDExactInput(uint256 amountIn, uint256 amountOutMinimum, uint160 limitSqrtPrice)
        external
        payable
    {
        require(msg.value == amountIn, "Incorrect cBTC amount sent");

        // Wrap cBTC to WCBTC
        WCBTC.deposit{value: amountIn}();

        _executeExactInputSwap(address(WCBTC), address(nUSD), amountIn, amountOutMinimum, limitSqrtPrice);
        _transferRemainingBalances();
    }

    function swapCBTCToNUSDExactOutput(uint256 amountOut, uint256 amountInMaximum, uint160 limitSqrtPrice)
        external
        payable
    {
        require(msg.value == amountInMaximum, "Incorrect cBTC amount sent");

        // Wrap cBTC to WCBTC
        WCBTC.deposit{value: amountInMaximum}();

        _executeExactOutputSwap(address(WCBTC), address(nUSD), amountOut, amountInMaximum, limitSqrtPrice);
        _transferRemainingBalancesWithCBTCConversion();
    }

    /// @notice Only receive cBTC from WCBTC withdraw
    receive() external payable {
        require(msg.sender == address(WCBTC), UnauthorizedDeposit(msg.sender, address(WCBTC)));
    }
}
