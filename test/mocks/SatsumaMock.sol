// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

import {IERC20} from "src/interfaces/IERC20.sol";
import {IWCBTC} from "src/interfaces/IWCBTC.sol";
import {IQuoterV2} from "src/interfaces/Satsuma/IQuoterV2.sol";
import {ISwapRouter} from "src/interfaces/Satsuma/ISwapRouter.sol";

contract SatsumaMock is Test, ISwapRouter, IQuoterV2 {
    uint256 public constant UNIT = 1 ether;

    NUSDToken public nUSD;
    IERC20 public USDC;
    IWCBTC public WCBTC;
    address public owner;
    OracleAggregator public oracle;
    uint256 public slippageAndFees;
    uint256 public slippageUSDCWCBTC;
    uint256 public slippageNUSDUSDC;

    // Track accumulated fees for testing
    uint256 public accumulatedFeesNUSD;
    uint256 public accumulatedFeesWCBTC;

    constructor(address _nectraUSD, address _usdc, address _nectra, address _oracle, address _WCBTC) {
        nUSD = NUSDToken(_nectraUSD);
        USDC = IERC20(_usdc);
        WCBTC = IWCBTC(_WCBTC);
        owner = _nectra;
        oracle = OracleAggregator(_oracle);
    }

    // ============ IQUOTERV2 IMPLEMENTATION ============

    function quoteExactInput(bytes memory, /* path */ uint256 /* amountInRequired */ )
        external
        pure
        returns (
            uint256[] memory, /* amountOutList */
            uint256[] memory, /* amountInList */
            uint160[] memory, /* sqrtPriceX96AfterList */
            uint32[] memory, /* initializedTicksCrossedList */
            uint256, /* gasEstimate */
            uint16[] memory /* feeList */
        )
    {
        // Not implemented for multi-hop swaps in this mock
        revert("Multi-hop swaps not supported in mock");
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        returns (
            uint256 amountOut,
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate,
            uint16 fee
        )
    {
        amountIn = params.amountIn;

        if (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC)) {
            // nUSD -> WCBTC
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * UNIT / price;
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD)) {
            // WCBTC -> nUSD
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * price / UNIT;
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * UNIT / price;
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * price / UNIT;
        } else if (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC)) {
            amountOut = params.amountIn;
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD)) {
            amountOut = params.amountIn;
        } else {
            revert("Unsupported token pair");
        }

        // Apply slippage and fees (reduce output)
        if (
            slippageAndFees > 0
                && (
                    (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC))
                        || (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD))
                )
        ) {
            amountOut = amountOut * (UNIT - slippageAndFees) / UNIT;
        }
        if (
            slippageUSDCWCBTC > 0
                && (
                    (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC))
                        || (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC))
                )
        ) {
            amountOut = amountOut * (UNIT - slippageUSDCWCBTC) / UNIT;
        }
        if (
            slippageNUSDUSDC > 0
                && (
                    (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC))
                        || (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD))
                )
        ) {
            amountOut = amountOut * (UNIT - slippageNUSDUSDC) / UNIT;
        }

        sqrtPriceX96After = 0; // Mock value
        initializedTicksCrossed = 1; // Mock value
        gasEstimate = 200000; // Mock value
        fee = 3000; // 0.3% fee mock
    }

    function quoteExactOutput(bytes memory, /* path */ uint256 /* amountOutRequired */ )
        external
        pure
        returns (
            uint256[] memory, /* amountOutList */
            uint256[] memory, /* amountInList */
            uint160[] memory, /* sqrtPriceX96AfterList */
            uint32[] memory, /* initializedTicksCrossedList */
            uint256, /* gasEstimate */
            uint16[] memory /* feeList */
        )
    {
        // Not implemented for multi-hop swaps in this mock
        revert("Multi-hop swaps not supported in mock");
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        view
        returns (
            uint256 amountOut,
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate,
            uint16 fee
        )
    {
        amountOut = params.amount;

        if (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC)) {
            // nUSD -> WCBTC
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amount * price / UNIT;
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD)) {
            // WCBTC -> nUSD
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amount * UNIT / price;
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amount * price / UNIT;
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amount * UNIT / price;
        } else if (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC)) {
            amountIn = params.amount;
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD)) {
            amountIn = params.amount;
        } else {
            revert("Unsupported token pair");
        }

        // Apply slippage and fees (increase input required)
        if (
            slippageAndFees > 0
                && (
                    (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC))
                        || (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD))
                )
        ) {
            amountIn = amountIn * (UNIT + slippageAndFees) / UNIT;
        }
        if (
            slippageUSDCWCBTC > 0
                && (
                    (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC))
                        || (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC))
                )
        ) {
            amountIn = amountIn * (UNIT + slippageUSDCWCBTC) / UNIT;
        }
        if (
            slippageNUSDUSDC > 0
                && (
                    (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC))
                        || (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD))
                )
        ) {
            amountIn = amountIn * (UNIT + slippageNUSDUSDC) / UNIT;
        }

        sqrtPriceX96After = 0; // Mock value
        initializedTicksCrossed = 1; // Mock value
        gasEstimate = 200000; // Mock value
        fee = 3000; // 0.3% fee mock
    }

    // ============ ISWAPROUTER IMPLEMENTATION ============

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        require(params.deadline >= block.timestamp, "Transaction too old");

        if (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC)) {
            // nUSD -> WCBTC
            nUSD.transferFrom(msg.sender, address(this), params.amountIn);

            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * UNIT / price;

            // Apply slippage and fees
            uint256 fees = 0;
            if (slippageAndFees > 0) {
                fees = amountOut * slippageAndFees / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesWCBTC += fees;
            }

            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

            WCBTC.transfer(params.recipient, amountOut);
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD)) {
            // WCBTC -> nUSD
            WCBTC.transferFrom(msg.sender, address(this), params.amountIn);

            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * price / UNIT;

            // Apply slippage and fees
            uint256 fees = 0;
            if (slippageAndFees > 0) {
                fees = amountOut * slippageAndFees / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesNUSD += fees;
            }

            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

            nUSD.transfer(params.recipient, amountOut);
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC)) {
            USDC.transferFrom(msg.sender, address(this), params.amountIn);
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * UNIT / price;
            uint256 fees = 0;
            if (slippageUSDCWCBTC > 0) {
                fees = amountOut * slippageUSDCWCBTC / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesWCBTC += fees;
            }
            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");
            WCBTC.transfer(params.recipient, amountOut);
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC)) {
            WCBTC.transferFrom(msg.sender, address(this), params.amountIn);
            (uint256 price,) = oracle.getLatestPrice();
            amountOut = params.amountIn * price / UNIT;
            uint256 fees = 0;
            if (slippageUSDCWCBTC > 0) {
                fees = amountOut * slippageUSDCWCBTC / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesNUSD += fees;
            }
            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");
            USDC.transfer(params.recipient, amountOut);
        } else if (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC)) {
            nUSD.transferFrom(msg.sender, address(this), params.amountIn);
            amountOut = params.amountIn;
            uint256 fees = 0;
            if (slippageNUSDUSDC > 0) {
                fees = amountOut * slippageNUSDUSDC / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesNUSD += fees;
            }
            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");
            USDC.transfer(params.recipient, amountOut);
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD)) {
            USDC.transferFrom(msg.sender, address(this), params.amountIn);
            amountOut = params.amountIn;
            uint256 fees = 0;
            if (slippageNUSDUSDC > 0) {
                fees = amountOut * slippageNUSDUSDC / UNIT;
                amountOut = amountOut - fees;
                accumulatedFeesNUSD += fees;
            }
            require(amountOut >= params.amountOutMinimum, "Insufficient output amount");
            nUSD.transfer(params.recipient, amountOut);
        } else {
            revert("Unsupported token pair");
        }
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        require(params.deadline >= block.timestamp, "Transaction too old");

        if (params.tokenIn == address(nUSD) && params.tokenOut == address(WCBTC)) {
            // nUSD -> WCBTC
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amountOut * price / UNIT;
            if (slippageAndFees > 0) amountIn = amountIn * (UNIT + slippageAndFees) / UNIT;

            require(amountIn <= params.amountInMaximum, "Excessive input amount");

            nUSD.transferFrom(msg.sender, address(this), amountIn);

            // Calculate fees
            uint256 fees = amountIn - (params.amountOut * price / UNIT);
            accumulatedFeesNUSD += fees;

            WCBTC.transfer(params.recipient, params.amountOut);
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(nUSD)) {
            // WCBTC -> nUSD
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amountOut * UNIT / price;
            if (slippageAndFees > 0) amountIn = amountIn * (UNIT + slippageAndFees) / UNIT;

            require(amountIn <= params.amountInMaximum, "Excessive input amount");

            WCBTC.transferFrom(msg.sender, address(this), amountIn);

            // Calculate fees
            uint256 fees = amountIn - (params.amountOut * UNIT / price);
            accumulatedFeesWCBTC += fees;

            nUSD.transfer(params.recipient, params.amountOut);
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(WCBTC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amountOut * price / UNIT;
            if (slippageUSDCWCBTC > 0) amountIn = amountIn * (UNIT + slippageUSDCWCBTC) / UNIT;
            require(amountIn <= params.amountInMaximum, "Excessive input amount");
            USDC.transferFrom(msg.sender, address(this), amountIn);
            WCBTC.transfer(params.recipient, params.amountOut);
        } else if (params.tokenIn == address(WCBTC) && params.tokenOut == address(USDC)) {
            (uint256 price,) = oracle.getLatestPrice();
            amountIn = params.amountOut * UNIT / price;
            if (slippageUSDCWCBTC > 0) amountIn = amountIn * (UNIT + slippageUSDCWCBTC) / UNIT;
            require(amountIn <= params.amountInMaximum, "Excessive input amount");
            WCBTC.transferFrom(msg.sender, address(this), amountIn);
            USDC.transfer(params.recipient, params.amountOut);
        } else if (params.tokenIn == address(nUSD) && params.tokenOut == address(USDC)) {
            amountIn = params.amountOut;
            if (slippageNUSDUSDC > 0) amountIn = amountIn * (UNIT + slippageNUSDUSDC) / UNIT;
            require(amountIn <= params.amountInMaximum, "Excessive input amount");
            nUSD.transferFrom(msg.sender, address(this), amountIn);
            USDC.transfer(params.recipient, params.amountOut);
        } else if (params.tokenIn == address(USDC) && params.tokenOut == address(nUSD)) {
            amountIn = params.amountOut;
            if (slippageNUSDUSDC > 0) amountIn = amountIn * (UNIT + slippageNUSDUSDC) / UNIT;
            require(amountIn <= params.amountInMaximum, "Excessive input amount");
            USDC.transferFrom(msg.sender, address(this), amountIn);
            nUSD.transfer(params.recipient, params.amountOut);
        } else {
            revert("Unsupported token pair");
        }
    }

    // ============ ADMIN FUNCTIONS ============

    function setSlippageAndFees(uint256 _slippageAndFees) external {
        slippageAndFees = _slippageAndFees;
    }

    function setSlippageUSDCWCBTC(uint256 v) external {
        slippageUSDCWCBTC = v;
    }

    function setSlippageNUSDUSDC(uint256 v) external {
        slippageNUSDUSDC = v;
    }

    function getAccumulatedFees() external view returns (uint256 nusdFees, uint256 wcbtcFees) {
        return (accumulatedFeesNUSD, accumulatedFeesWCBTC);
    }

    function resetAccumulatedFees() external {
        accumulatedFeesNUSD = 0;
        accumulatedFeesWCBTC = 0;
    }

    // Allow contract to receive ETH for cBTC operations
    receive() external payable {}
}
