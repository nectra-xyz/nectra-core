// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {SatsumaHandler} from "src/auxiliary/SatsumaHandler.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {SatsumaMock} from "test/mocks/SatsumaMock.sol";
import {WCBTCMock} from "test/mocks/WCBTCMock.sol";
import {OracleAggregatorMock} from "test/mocks/OracleAggregatorMock.sol";
import {IERC20} from "src/interfaces/IERC20.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {console} from "forge-std/console.sol";

contract SatsumaHandlerTest is Test {
    uint256 constant UNIT = 1 ether;
    uint256 constant BTC_PRICE = 65000 * UNIT; // $65,000 per BTC

    SatsumaHandler internal handler;
    SatsumaMock internal satsumaMock;
    WCBTCMock internal wcbtc;
    NUSDToken internal nusd;
    OracleAggregatorMock internal oracle;

    address internal nectra = makeAddr("nectra");
    address internal user = makeAddr("user");
    address internal trader = makeAddr("trader");

    function setUp() public {
        // Deploy oracle with BTC price
        oracle = new OracleAggregatorMock(BTC_PRICE);

        // Deploy tokens
        address nusdProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new NUSDToken()),
            abi.encodeCall(NUSDToken.initialize, (address(this), nectra))
        );
        nusd = NUSDToken(nusdProxy);

        wcbtc = new WCBTCMock();

        // Deploy DEX mock
        satsumaMock = new SatsumaMock(address(nusd), address(0), nectra, address(oracle), address(wcbtc));

        satsumaMock.setSlippageAndFees(0.01 ether); // 1% slippage and fees

        // Deploy SatsumaHandler
        handler = new SatsumaHandler(
            address(satsumaMock), // swapRouter
            address(satsumaMock), // quoter
            address(nusd),
            address(wcbtc)
        );

        // Setup initial balances
        deal(user, 100 ether); // 100 cBTC
        deal(trader, 10 ether); // 10 cBTC

        // Mint initial NUSD and WCBTC to users for testing
        vm.prank(nectra);
        nusd.mint(user, 1000000 * UNIT); // 1M nUSD

        // Mint WCBTC to users by depositing cBTC
        vm.prank(user);
        wcbtc.deposit{value: 50 ether}(); // Convert 50 cBTC to WCBTC

        vm.prank(trader);
        wcbtc.deposit{value: 5 ether}(); // Convert 5 cBTC to WCBTC

        // Give DEX mock some WCBTC to handle swaps
        vm.prank(nectra);
        nusd.mint(address(satsumaMock), 10000000 * UNIT); // 10M nUSD for liquidity

        deal(address(satsumaMock), 1000 ether); // 1000 cBTC for liquidity
        wcbtc.deposit{value: 500 ether}(); // Convert to WCBTC
        wcbtc.transfer(address(satsumaMock), 500 ether); // Give DEX some WCBTC
    }

    // ============ QUOTE TESTS ============

    function test_getNUSDToWCBTCExactInputQuote() public {
        uint256 amountIn = 65000 * UNIT; // $65,000 nUSD
        uint160 limitSqrtPrice = 0;

        (uint256 amountOut, uint160 sqrtPriceX96After) = handler.getNUSDToWCBTCExactInputQuote(amountIn, limitSqrtPrice);

        // Should get approximately 1 WCBTC for $65,000 nUSD
        assertApproxEqRel(amountOut, 1 ether, 0.01e18); // Within 1%
        assertTrue(sqrtPriceX96After == 0); // Mock value
    }

    function test_getNUSDToWCBTCExactOutputQuote() public {
        uint256 amountOut = 1 ether; // 1 WCBTC
        uint160 limitSqrtPrice = 0;

        (uint256 amountIn, uint160 sqrtPriceX96After) =
            handler.getNUSDToWCBTCExactOutputQuote(amountOut, limitSqrtPrice);

        // Should need approximately $65,000 nUSD for 1 WCBTC
        assertApproxEqRel(amountIn, BTC_PRICE, 0.01e18); // Within 1%
        assertTrue(sqrtPriceX96After == 0); // Mock value
    }

    function test_getWCBTCToNUSDExactInputQuote() public {
        uint256 amountIn = 1 ether; // 1 WCBTC
        uint160 limitSqrtPrice = 0;

        (uint256 amountOut, uint160 sqrtPriceX96After) = handler.getWCBTCToNUSDExactInputQuote(amountIn, limitSqrtPrice);

        // Should get approximately $65,000 nUSD for 1 WCBTC
        assertApproxEqRel(amountOut, BTC_PRICE, 0.01e18); // Within 1%
        assertTrue(sqrtPriceX96After == 0); // Mock value
    }

    function test_getWCBTCToNUSDExactOutputQuote() public {
        uint256 amountOut = BTC_PRICE; // $65,000 nUSD
        uint160 limitSqrtPrice = 0;

        (uint256 amountIn, uint160 sqrtPriceX96After) =
            handler.getWCBTCToNUSDExactOutputQuote(amountOut, limitSqrtPrice);

        // Should need approximately 1 WCBTC for $65,000 nUSD
        assertApproxEqRel(amountIn, 1 ether, 0.01e18); // Within 1%
        assertTrue(sqrtPriceX96After == 0); // Mock value
    }

    function test_getCBTCToNUSDExactInputQuote() public {
        uint256 amountIn = 1 ether; // 1 cBTC
        uint160 limitSqrtPrice = 0;

        (uint256 amountOut, uint160 sqrtPriceX96After) = handler.getCBTCToNUSDExactInputQuote(amountIn, limitSqrtPrice);

        // Should get approximately $65,000 nUSD for 1 cBTC
        assertApproxEqRel(amountOut, BTC_PRICE, 0.01e18); // Within 1%
        assertTrue(sqrtPriceX96After == 0); // Mock value
    }

    // ============ nUSD -> WCBTC SWAP TESTS ============

    function test_swapNUSDToWCBTCExactInput() public {
        uint256 amountIn = 65000 * UNIT; // $65,000 nUSD
        uint256 amountOutMinimum = 0.99 ether; // Accept slight slippage
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userNUSDBefore = nusd.balanceOf(user);
        uint256 userWCBTCBefore = wcbtc.balanceOf(user);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Approve handler to spend nUSD
        vm.prank(user);
        nusd.approve(address(handler), amountIn);

        // Execute swap
        vm.prank(user);
        handler.swapNUSDToWCBTCExactInput(amountIn, amountOutMinimum, limitSqrtPrice);

        // Check balances after
        uint256 userNUSDAfter = nusd.balanceOf(user);
        uint256 userWCBTCAfter = wcbtc.balanceOf(user);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user spent nUSD and received WCBTC
        assertEq(userNUSDBefore - userNUSDAfter, amountIn, "User should have spent exact nUSD amount");
        assertTrue(userWCBTCAfter > userWCBTCBefore, "User should have received WCBTC");
        assertGe(userWCBTCAfter - userWCBTCBefore, amountOutMinimum, "User should have received at least minimum WCBTC");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    function test_swapNUSDToWCBTCExactOutput() public {
        uint256 amountOut = 1 ether; // 1 WCBTC
        uint256 amountInMaximum = 70000 * UNIT; // $70,000 nUSD max
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userNUSDBefore = nusd.balanceOf(user);
        uint256 userWCBTCBefore = wcbtc.balanceOf(user);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Approve handler to spend nUSD
        vm.prank(user);
        nusd.approve(address(handler), amountInMaximum);

        // Execute swap
        vm.prank(user);
        handler.swapNUSDToWCBTCExactOutput(amountOut, amountInMaximum, limitSqrtPrice);

        // Check balances after
        uint256 userNUSDAfter = nusd.balanceOf(user);
        uint256 userWCBTCAfter = wcbtc.balanceOf(user);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user received exact WCBTC and spent appropriate nUSD
        assertEq(userWCBTCAfter - userWCBTCBefore, amountOut, "User should have received exact WCBTC amount");
        assertTrue(userNUSDBefore > userNUSDAfter, "User should have spent nUSD");
        assertLe(userNUSDBefore - userNUSDAfter, amountInMaximum, "User should not have spent more than maximum");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    function test_swapNUSDToCBTCExactOutput() public {
        uint256 amountOut = 1 ether; // 1 cBTC
        uint256 amountInMaximum = 70000 * UNIT; // $70,000 nUSD max
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userNUSDBefore = nusd.balanceOf(user);
        uint256 userCBTCBefore = user.balance;
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Approve handler to spend nUSD
        vm.prank(user);
        nusd.approve(address(handler), amountInMaximum);

        // Execute swap
        vm.prank(user);
        handler.swapNUSDToCBTCExactOutput(amountOut, amountInMaximum, limitSqrtPrice);

        // Check balances after
        uint256 userNUSDAfter = nusd.balanceOf(user);
        uint256 userCBTCAfter = user.balance;
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user received exact cBTC and spent appropriate nUSD
        assertEq(userCBTCAfter - userCBTCBefore, amountOut, "User should have received exact cBTC amount");
        assertTrue(userNUSDBefore > userNUSDAfter, "User should have spent nUSD");
        assertLe(userNUSDBefore - userNUSDAfter, amountInMaximum, "User should not have spent more than maximum");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    // ============ WCBTC -> nUSD SWAP TESTS ============

    function test_swapWCBTCToNUSDExactInput() public {
        uint256 amountIn = 1 ether; // 1 WCBTC
        uint256 amountOutMinimum = 64000 * UNIT; // $64,000 nUSD minimum
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userWCBTCBefore = wcbtc.balanceOf(user);
        uint256 userNUSDBefore = nusd.balanceOf(user);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Approve handler to spend WCBTC
        vm.prank(user);
        wcbtc.approve(address(handler), amountIn);

        // Execute swap
        vm.prank(user);
        handler.swapWCBTCToNUSDExactInput(amountIn, amountOutMinimum, limitSqrtPrice);

        // Check balances after
        uint256 userWCBTCAfter = wcbtc.balanceOf(user);
        uint256 userNUSDAfter = nusd.balanceOf(user);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user spent WCBTC and received nUSD
        assertEq(userWCBTCBefore - userWCBTCAfter, amountIn, "User should have spent exact WCBTC amount");
        assertTrue(userNUSDAfter > userNUSDBefore, "User should have received nUSD");
        assertGe(userNUSDAfter - userNUSDBefore, amountOutMinimum, "User should have received at least minimum nUSD");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    function test_swapWCBTCToNUSDExactOutput() public {
        uint256 amountOut = BTC_PRICE; // $65,000 nUSD
        uint256 amountInMaximum = 1.1 ether; // 1.1 WCBTC max
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userWCBTCBefore = wcbtc.balanceOf(user);
        uint256 userNUSDBefore = nusd.balanceOf(user);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Approve handler to spend WCBTC
        vm.prank(user);
        wcbtc.approve(address(handler), amountInMaximum);

        // Execute swap
        vm.prank(user);
        handler.swapWCBTCToNUSDExactOutput(amountOut, amountInMaximum, limitSqrtPrice);

        // Check balances after
        uint256 userWCBTCAfter = wcbtc.balanceOf(user);
        uint256 userNUSDAfter = nusd.balanceOf(user);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user received exact nUSD and spent appropriate WCBTC
        assertEq(userNUSDAfter - userNUSDBefore, amountOut, "User should have received exact nUSD amount");
        assertTrue(userWCBTCBefore > userWCBTCAfter, "User should have spent WCBTC");
        assertLe(userWCBTCBefore - userWCBTCAfter, amountInMaximum, "User should not have spent more than maximum");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    // ============ cBTC -> nUSD SWAP TESTS ============

    function test_swapCBTCToNUSDExactInput() public {
        uint256 amountIn = 1 ether; // 1 cBTC
        uint256 amountOutMinimum = 64000 * UNIT; // $64,000 nUSD minimum
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userCBTCBefore = trader.balance;
        uint256 userNUSDBefore = nusd.balanceOf(trader);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Execute swap
        vm.prank(trader);
        handler.swapCBTCToNUSDExactInput{value: amountIn}(amountIn, amountOutMinimum, limitSqrtPrice);

        // Check balances after
        uint256 userCBTCAfter = trader.balance;
        uint256 userNUSDAfter = nusd.balanceOf(trader);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user spent cBTC and received nUSD
        assertEq(userCBTCBefore - userCBTCAfter, amountIn, "User should have spent exact cBTC amount");
        assertTrue(userNUSDAfter > userNUSDBefore, "User should have received nUSD");
        assertGe(userNUSDAfter - userNUSDBefore, amountOutMinimum, "User should have received at least minimum nUSD");

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    function test_swapCBTCToNUSDExactOutput() public {
        uint256 amountOut = BTC_PRICE; // $65,000 nUSD
        uint256 amountInMaximum = 1.1 ether; // 1.1 cBTC max
        uint160 limitSqrtPrice = 0;

        // Record initial balances
        uint256 userCBTCBefore = trader.balance;
        uint256 userNUSDBefore = nusd.balanceOf(trader);
        uint256 handlerNUSDBefore = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCBefore = wcbtc.balanceOf(address(handler));

        // Execute swap
        vm.prank(trader);
        handler.swapCBTCToNUSDExactOutput{value: amountInMaximum}(amountOut, amountInMaximum, limitSqrtPrice);

        // Check balances after
        uint256 userCBTCAfter = trader.balance;
        uint256 userNUSDAfter = nusd.balanceOf(trader);
        uint256 handlerNUSDAfter = nusd.balanceOf(address(handler));
        uint256 handlerWCBTCAfter = wcbtc.balanceOf(address(handler));

        // Verify user received exact nUSD and spent appropriate cBTC
        assertEq(userNUSDAfter - userNUSDBefore, amountOut, "User should have received exact nUSD amount");
        assertTrue(userCBTCBefore > userCBTCAfter, "User should have spent cBTC");
        // Note: In exact output, remaining cBTC should be refunded
        // The exact amount spent depends on slippage/fees

        // Verify no tokens left in handler
        assertEq(handlerNUSDAfter, handlerNUSDBefore, "Handler should have no nUSD balance change");
        assertEq(handlerWCBTCAfter, handlerWCBTCBefore, "Handler should have no WCBTC balance change");
    }

    // ============ SLIPPAGE AND FEES TESTS ============

    function test_slippageAndFeesAreAccumulated() public {
        // Set 1% slippage and fees
        satsumaMock.setSlippageAndFees(0.01 ether);

        uint256 amountIn = 1 ether; // 1 WCBTC
        uint256 amountOutMinimum = 0; // Accept any output for this test
        uint160 limitSqrtPrice = 0;

        // Get initial accumulated fees
        (uint256 initialNUSDFees, uint256 initialWCBTCFees) = satsumaMock.getAccumulatedFees();

        // Approve and execute swap
        vm.prank(user);
        wcbtc.approve(address(handler), amountIn);

        vm.prank(user);
        handler.swapWCBTCToNUSDExactInput(amountIn, amountOutMinimum, limitSqrtPrice);

        // Get final accumulated fees
        (uint256 finalNUSDFees, uint256 finalWCBTCFees) = satsumaMock.getAccumulatedFees();

        // Verify fees were accumulated in the DEX
        assertTrue(finalNUSDFees > initialNUSDFees, "DEX should have accumulated nUSD fees");

        // Calculate expected fee
        uint256 expectedOutput = BTC_PRICE;
        uint256 expectedFee = expectedOutput * 0.01 ether / UNIT;
        assertApproxEqRel(finalNUSDFees - initialNUSDFees, expectedFee, 0.01e18); // Within 1%
    }

    function test_slippageProtection() public {
        // Set 5% slippage
        satsumaMock.setSlippageAndFees(0.05 ether);

        uint256 amountIn = 65000 * UNIT; // $65,000 nUSD
        uint256 amountOutMinimum = 0.98 ether; // Expect at least 0.98 WCBTC (strict minimum)
        uint160 limitSqrtPrice = 0;

        // Approve handler to spend nUSD
        vm.prank(user);
        nusd.approve(address(handler), amountIn);

        // This should revert due to slippage protection
        vm.prank(user);
        vm.expectRevert("Insufficient output amount");
        handler.swapNUSDToWCBTCExactInput(amountIn, amountOutMinimum, limitSqrtPrice);
    }

    // ============ ERROR HANDLING TESTS ============

    function test_revert_swapCBTCToNUSDExactInput_incorrectValue() public {
        uint256 amountIn = 1 ether;
        uint256 incorrectValue = 0.5 ether;

        vm.prank(trader);
        vm.expectRevert("Incorrect cBTC amount sent");
        handler.swapCBTCToNUSDExactInput{value: incorrectValue}(amountIn, 0, 0);
    }

    function test_revert_swapCBTCToNUSDExactOutput_incorrectValue() public {
        uint256 amountOut = BTC_PRICE;
        uint256 amountInMaximum = 1.1 ether;
        uint256 incorrectValue = 0.5 ether;

        vm.prank(trader);
        vm.expectRevert("Incorrect cBTC amount sent");
        handler.swapCBTCToNUSDExactOutput{value: incorrectValue}(amountOut, amountInMaximum, 0);
    }

    function test_unauthorized_receive() public {
        // Test that the handler only accepts ETH from WCBTC
        vm.expectRevert();
        payable(address(handler)).transfer(1 ether);
    }

    // ============ INTEGRATION TESTS ============

    function test_roundTripSwap() public {
        uint256 initialNUSD = 65000 * UNIT;
        uint256 minWCBTC = 0.99 ether;
        uint256 minNUSDBack = 63700 * UNIT; // 2% loss (1% per swap)

        // Record initial balance
        uint256 userCBTCInitial = wcbtc.balanceOf(user);
        uint256 userNUSDInitial = nusd.balanceOf(user);

        // First swap: nUSD -> WCBTC
        vm.prank(user);
        nusd.approve(address(handler), initialNUSD);

        vm.prank(user);
        handler.swapNUSDToWCBTCExactInput(initialNUSD, minWCBTC, 0);

        uint256 wcbtcReceived = wcbtc.balanceOf(user) - userCBTCInitial;
        assertTrue(wcbtcReceived >= minWCBTC, "Should receive minimum WCBTC");

        // Second swap: WCBTC -> nUSD
        vm.prank(user);
        wcbtc.approve(address(handler), wcbtcReceived);

        vm.prank(user);
        handler.swapWCBTCToNUSDExactInput(wcbtcReceived, minNUSDBack, 0);

        uint256 userNUSDFinal = nusd.balanceOf(user);

        // Should get back less than initial due to slippage/fees, but more than minimum
        assertTrue(userNUSDFinal >= userNUSDInitial - initialNUSD + minNUSDBack, "Should receive minimum nUSD back");
        assertTrue(userNUSDFinal < userNUSDInitial, "Should lose some value to fees");

        // Verify no tokens left in handler
        assertEq(nusd.balanceOf(address(handler)), 0, "Handler should have no nUSD left");
        assertEq(wcbtc.balanceOf(address(handler)), 0, "Handler should have no WCBTC left");
    }
}
