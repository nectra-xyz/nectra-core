// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";
import {NectraFlashHandler} from "src/auxiliary/NectraFlashHandler.sol";
import {SatsumaHandler} from "src/auxiliary/SatsumaHandler.sol";
import {SatsumaMock} from "test/mocks/SatsumaMock.sol";
import {WCBTCMock} from "test/mocks/WCBTCMock.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {OracleAggregatorMock} from "test/mocks/OracleAggregatorMock.sol";

contract NectraFlashHandlerTest is NectraBaseTest {
    uint256 constant BTC_PRICE = 65000 * UNIT; // $65,000 per BTC

    NectraFlashHandler internal flashHandler;
    SatsumaHandler internal satsumaHandler;
    SatsumaMock internal satsumaMock;
    WCBTCMock internal wcbtc;

    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");
    
    uint256 dexFeesAndSlippage = 0.008 ether; // 0.8% slippage and fees

    function _createPosition(address _user, uint256 _initialCollateral, uint256 _desiredCollateral) internal returns (uint256 tokenId, uint256 maxDebt) {
        uint256 flashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (_desiredCollateral - _initialCollateral) / UNIT;
        (uint256 swapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(flashBorrowAmountWithFees, 0);
        maxDebt = swapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT;
        
        vm.prank(_user);
        tokenId = flashHandler.increasePositionExposure{value: _initialCollateral}(
            0,
            _desiredCollateral, // > initialCollateral
            0.05 ether,
            maxDebt,
            _user
        );
    }

    function setUp() public override {
        cargs.flashBorrowFee = 0.0025 ether;   // 0.25%
        cargs.flashMintFee = 0.0025 ether;     // 0.25%
        cargs.openFeePercentage = 0.002 ether; // 0.2%
        super.setUp();

        // Deploy WCBTC mock
        wcbtc = new WCBTCMock();

        // Deploy Satsuma mock
        satsumaMock = new SatsumaMock(
            address(nectraUSD), 
            address(nectra), 
            address(oracle), 
            address(wcbtc)
        );
        satsumaMock.setSlippageAndFees(dexFeesAndSlippage); // 0.8% slippage and fees

        // Deploy SatsumaHandler wrapping the mock
        satsumaHandler = new SatsumaHandler(
            address(satsumaMock), // swapRouter
            address(satsumaMock), // quoter
            address(nectraUSD),
            address(wcbtc)
        );

        // Deploy NectraFlashHandler
        flashHandler = new NectraFlashHandler(
            address(nectraUSD),
            address(nectra),
            address(nectraNFT),
            address(nectraExternal),
            address(oracle),
            payable(address(satsumaHandler))
        );

        // Set oracle price
        oracle.setCurrentPrice(BTC_PRICE);

        // Setup liquidity in the DEX mock
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, int256(10000000 * UNIT),  0.05 ether, "");
        nectraUSD.transfer(address(satsumaMock), 10000000 * UNIT); // 10M nUSD

        deal(address(satsumaMock), 500 ether); // 1000 cBTC
        wcbtc.deposit{value: 500 ether}(); // Convert to WCBTC
        wcbtc.transfer(address(satsumaMock), 500 ether); // Give DEX some WCBTC

        // Setup users with initial balances
        deal(user, 100 ether); // 100 cBTC
        deal(user2, 50 ether); // 50 cBTC

        // Give user some WCBTC
        vm.prank(user);
        wcbtc.deposit{value: 10 ether}();

        
    }

    // ============ CREATE LEVERAGED POSITION TESTS ============

    function test_increasePositionExposure_createNewPosition() public {
        // Record initial balances
        uint256 userBalanceBefore = user.balance;

        // create position
        uint256 initialCollateral = 5 ether; // User provides 5 cBTC
        uint256 desiredCollateral = 10 ether; // Wants 10 cBTC total (2x leverage)
        (uint256 tokenId, uint256 maxDebt) = _createPosition(user, initialCollateral, desiredCollateral);

        // Verify position was created
        assertTrue(tokenId > 0, "Position should be created");
        assertEq(nectraNFT.ownerOf(tokenId), user, "NFT should be sent to user");

        // Verify position properties
        (uint256 collateral, uint256 debt, uint256 interestRate) = nectraExternal.getPosition(tokenId);
        assertEq(collateral, desiredCollateral, "Position should have desired collateral");
        assertEq(interestRate, 0.05 ether, "Position should have desired interest rate");
        assertTrue(debt > 0, "Position should have debt");
        assertTrue(debt <= maxDebt, "Debt should not exceed maximum");

        // Verify user paid the correct amount
        assertEq(user.balance, userBalanceBefore - initialCollateral, "User should have paid msg.value");

        // Verify no tokens left in handler
        assertEq(address(flashHandler).balance, 0, "Handler should have no cBTC left");
        assertEq(nectraUSD.balanceOf(address(flashHandler)), 0, "Handler should have no nUSD left");
        assertEq(wcbtc.balanceOf(address(flashHandler)), 0, "Handler should have no WCBTC left");
    }

    function test_increasePositionExposure_modifyExistingPosition() public {
        // First create a position
        uint256 initialCollateral = 5 ether;
        uint256 desiredCollateral = 10 ether;
        (uint256 tokenId,) = _createPosition(user, initialCollateral, desiredCollateral);

        // Record initial position state
        (, uint256 debtBefore,) = nectraExternal.getPosition(tokenId);

        // Now increase the position
        uint256 additionalValue = 3 ether;
        uint256 newDesiredCollateral = 15 ether;
        uint256 newFlashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (newDesiredCollateral - desiredCollateral - additionalValue) / UNIT;
        (uint256 AdditionalSwapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(newFlashBorrowAmountWithFees, 0);
        uint256 newMaxDebt = AdditionalSwapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT + debtBefore;

        // Authorize flash handler for deposit and borrow
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Deposit);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Borrow);

        vm.prank(user);
        nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

        vm.prank(user);
        uint256 returnedTokenId = flashHandler.increasePositionExposure{value: additionalValue}(
            tokenId,
            newDesiredCollateral,
            0.05 ether,
            newMaxDebt,
            user
        );

        // Verify same token ID returned
        assertEq(returnedTokenId, tokenId, "Should return same token ID");

        // Verify position was modified
        (uint256 collateralAfter, uint256 debtAfter,) = nectraExternal.getPosition(tokenId);
        assertEq(collateralAfter, newDesiredCollateral, "Collateral should be increased");
        assertGe(debtAfter, debtBefore, "Debt should be increased");
        assertLe(debtAfter, newMaxDebt, "Debt should not exceed new maximum");

        // Verify no tokens left in handler
        assertEq(address(flashHandler).balance, 0, "Handler should have no cBTC left");
        assertEq(nectraUSD.balanceOf(address(flashHandler)), 0, "Handler should have no nUSD left");
    }

    function test_increasePositionExposure_revertIfDesiredCollateralTooLow() public {
        uint256 msgValue = 1 ether;
        uint256 desiredCollateral = 1 ether; // Equal to msg.value (should be greater)
        uint256 maxDebt = BTC_PRICE * (UNIT + cargs.openFeePercentage + cargs.flashBorrowFee + dexFeesAndSlippage) / UNIT;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraFlashHandler.DesiredCollateralTooLow.selector,
                desiredCollateral,
                msgValue
            )
        );
        flashHandler.increasePositionExposure{value: msgValue}(
            0,
            desiredCollateral,
            0.05 ether,
            maxDebt,
            user
        );
    }

    function test_increasePositionExposure_revertIfDesiredCollateralTooLowForExistingPosition() public {
        // First create a position
        uint256 initialCollateral = 1 ether;
        uint256 desiredCollateral = 2 ether;
        (uint256 tokenId,) = _createPosition(user, initialCollateral, desiredCollateral);

        // Authorize flash handler for deposit and borrow
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Deposit);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Borrow);

        vm.prank(user);
        nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

        // Try to modify with insufficient desired collateral
        uint256 msgValue = 1 ether;
        uint256 newDesiredCollateral = msgValue + desiredCollateral; // existing collateral

        vm.startPrank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NectraFlashHandler.DesiredCollateralTooLow.selector,
                    newDesiredCollateral,
                    msgValue + desiredCollateral
                )
            );
            flashHandler.increasePositionExposure{value: msgValue}(
                tokenId,
                newDesiredCollateral,
                0.05 ether,
                type(uint256).max,
                user
            );
        vm.stopPrank();
    }

    function test_increasePositionExposure_revertIfIssuanceRatioExceeded() public {
        uint256 msgValue = 1 ether;
        uint256 desiredCollateral = 2 ether; // > msgValue
        uint256 maxDebt = BTC_PRICE * desiredCollateral * 10; // Very high debt that would exceed issuance ratio

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.IssuanceRatioExceeded.selector, uint256(0), cargs.issuanceRatio)
        );
        flashHandler.increasePositionExposure{value: msgValue}(
            0,
            desiredCollateral,
            0.05 ether,
            maxDebt,
            user
        );
    }

    function test_increasePositionExposure_revertIfMaxDebtExceeded() public {
        uint256 msgValue = 1 ether;
        uint256 desiredCollateral = 10 ether; // > msgValue, high leverage
        
        uint256 flashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (desiredCollateral - msgValue) / UNIT;
        (uint256 swapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(flashBorrowAmountWithFees, 0);
        uint256 expectedDebt = swapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT;

        uint256 maxDebt = 1000 * UNIT; // Very low max debt

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.MaxDebtExceeded.selector, expectedDebt, maxDebt)
        );
        flashHandler.increasePositionExposure{value: msgValue}(
            0,
            desiredCollateral,
            0.05 ether,
            maxDebt,
            user
        );
    }

    // ============ CLOSE LEVERAGED POSITION TESTS ============

    function test_flashClosePosition_success() public {
        // First create a position
        uint256 initialCollateral = 1 ether;
        uint256 desiredCollateral = 2 ether;
        (uint256 tokenId,) = _createPosition(user, initialCollateral, desiredCollateral);

        // Record initial state
        uint256 recipientBalanceBefore = recipient.balance;

        // Authorize flash handler for repay and withdraw
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Withdraw);

        vm.prank(user);
        nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

        // Close the position
        (, uint256 debt, ) = nectraExternal.getPosition(tokenId);
        uint256 totalDebtCost = debt * (UNIT + cargs.flashMintFee) / UNIT;
        (uint256 swapAmountIn, ) = satsumaHandler.getWCBTCToNUSDExactOutputQuote(totalDebtCost, 0);
        uint256 minCollateralOut = desiredCollateral - swapAmountIn;

        vm.prank(user);
        uint256 collateralOut = flashHandler.flashClosePosition(
            tokenId,
            minCollateralOut,
            recipient
        );

        // Verify position is closed
        (uint256 positionCollateral, uint256 positionDebt,) = nectraExternal.getPosition(tokenId);
        assertEq(positionCollateral, 0, "Position should be closed");
        assertEq(positionDebt, 0, "Position should be closed");

        // Verify recipient received collateral
        assertTrue(collateralOut >= minCollateralOut, "Should receive minimum collateral");
        assertEq(recipient.balance, recipientBalanceBefore + collateralOut, "Recipient should receive collateral");

        // Verify no tokens left in handler
        assertEq(address(flashHandler).balance, 0, "Handler should have no cBTC left");
        assertEq(nectraUSD.balanceOf(address(flashHandler)), 0, "Handler should have no nUSD left");
    }

    function test_flashClosePosition_revertIfInsufficientCollateralOut() public {
        // Create a position
        (uint256 tokenId,) = _createPosition(user, 4 ether, 5 ether);

        // Try to close with unrealistic minimum collateral
        uint256 minCollateralOut = 50 ether; // Impossible to achieve
        (uint256 actualCollateralOut,,) = flashHandler.quoteClosePosition(tokenId, 0);
        
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Withdraw);

        vm.startPrank(user);
            nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NectraFlashHandler.InsufficientCollateralOut.selector,
                    actualCollateralOut,
                    minCollateralOut
                )
            );
            flashHandler.flashClosePosition(tokenId, minCollateralOut, recipient);
        vm.stopPrank();
    }

    // ============ AUTHORIZATION TESTS ============

    function test_increasePositionExposure_revertIfNotAuthorized() public {
        // Create a position as user
        (uint256 tokenId, uint256 maxDebt) = _createPosition(user, 5 ether, 10 ether);

        uint256 extraCollateral = 2 ether;
        uint256 newDesiredCollateral = 15 ether;
        uint256 newFlashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (newDesiredCollateral - 10 ether - extraCollateral) / UNIT;
        (uint256 AdditionalSwapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(newFlashBorrowAmountWithFees, 0);
        uint256 newMaxDebt = AdditionalSwapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT + maxDebt;

        // Try to modify as different user without authorization
        vm.startPrank(user2);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NectraFlashHandler.UnauthorizedCaller.selector,
                    user2,
                    user
                )
            );

            
            flashHandler.increasePositionExposure{value: extraCollateral}(
                tokenId,
                newDesiredCollateral,
                0.05 ether,
                newMaxDebt,
                user2
            );
        vm.stopPrank();
    }

    function test_flashClosePosition_revertIfNotAuthorized() public {
        // Create a position as user
        (uint256 tokenId,) = _createPosition(user, 1 ether, 2 ether);

        // Try to close as different user without authorization
        vm.startPrank(user2);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NectraFlashHandler.UnauthorizedCaller.selector,
                    user2,
                    user
                )
            );
            flashHandler.flashClosePosition(tokenId, 1 ether, user2);
        vm.stopPrank();
    }

    function test_increasePositionExposure_withAuthorization() public {
        // Create a position as user
        uint256 initialCollateral = 5 ether;
        uint256 desiredCollateral = 10 ether;
        (uint256 tokenId, uint256 maxDebt) = _createPosition(user, initialCollateral, desiredCollateral);

        // Authorize user2 for deposit and borrow
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Deposit);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Borrow);

        vm.startPrank(user);
            nectraNFT.authorize(tokenId, user2, permissionBitmask);
            nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);
        vm.stopPrank();

        // Now user2 should be able to modify the position
        deal(user2, 10 ether);
        uint256 newDesiredCollateral = 15 ether;
        uint256 extraCollateral = 2 ether;
        uint256 newFlashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (newDesiredCollateral - desiredCollateral - extraCollateral) / UNIT;
        (uint256 AdditionalSwapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(newFlashBorrowAmountWithFees, 0);
        uint256 newMaxDebt = AdditionalSwapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT + maxDebt;

        vm.prank(user2);
        flashHandler.increasePositionExposure{value: extraCollateral}(
            tokenId,
            newDesiredCollateral, // > 2 + 10 = 12 ether
            0.05 ether,
            newMaxDebt,
            user2
        );

        // Verify position was modified
        (uint256 collateral,,) = nectraExternal.getPosition(tokenId);
        assertEq(collateral, 15 ether, "Position should be modified");
    }

    function test_flashClosePosition_withAuthorization() public {
        // Create a position as user
        uint256 initialCollateral = 5 ether;
        uint256 desiredCollateral = 10 ether;
        (uint256 tokenId,) = _createPosition(user, initialCollateral, desiredCollateral);

        // Authorize user2 for repay and withdraw
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Withdraw);
        
        vm.startPrank(user);
            nectraNFT.authorize(tokenId, user2, permissionBitmask);
            nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);
        vm.stopPrank();

        // Now user2 should be able to close the position
        vm.prank(user2);
        flashHandler.flashClosePosition(tokenId, 1 ether, user2);

        // Verify position is closed
        (uint256 positionCollateral, uint256 positionDebt,) = nectraExternal.getPosition(tokenId);
        assertEq(positionCollateral, 0, "Position should be closed");
        assertEq(positionDebt, 0, "Position should be closed");
    }

    // ============ CALLBACK SECURITY TESTS ============

    function test_executeOperation_revertIfNotCalledByNectra() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraFlashHandler.UnauthorizedCaller.selector,
                attacker,
                address(nectra)
            )
        );
        flashHandler.executeOperation(
            address(0),
            1 ether,
            0.1 ether,
            address(flashHandler),
            ""
        );
    }

    function test_executeOperation_revertIfNotInitiatedByHandler() public {
        // This test simulates Nectra calling executeOperation but with wrong initiator
        vm.prank(address(nectra));
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraFlashHandler.UnauthorizedCaller.selector,
                attacker,
                address(flashHandler)
            )
        );
        flashHandler.executeOperation(
            address(0),
            1 ether,
            0.1 ether,
            attacker, // Wrong initiator
            ""
        );
    }

    function test_executeOperation_revertIfInvalidAsset() public {
        address invalidAsset = makeAddr("invalidAsset");
        
        vm.prank(address(nectra));
        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.InvalidAsset.selector, invalidAsset)
        );
        flashHandler.executeOperation(
            invalidAsset,
            1 ether,
            0.1 ether,
            address(flashHandler),
            ""
        );
    }

    // ============ QUOTE FUNCTION TESTS ============

    function test_quoteClosePosition() public {
        // Create a position
        uint256 desiredCollateral = 2 ether;
        (uint256 tokenId,) = _createPosition(user, 1 ether, desiredCollateral);

        // Get quote for closing
        (uint256 collateralOut, uint256 collateralToSwap, uint256 positionCollateral) = 
            flashHandler.quoteClosePosition(tokenId, 0);

        // Verify quote is reasonable
        assertTrue(collateralOut > 0, "Should expect some collateral out");
        assertTrue(collateralToSwap > 0, "Should need some collateral to swap");
        assertEq(positionCollateral, desiredCollateral, "Should return correct position collateral");
        assertEq(collateralOut + collateralToSwap, positionCollateral, "Should account for all collateral");
    }

    function test_quoteClosePosition_revertIfInvalidPosition() public {
        uint256 invalidTokenId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.InvalidPositionId.selector, invalidTokenId)
        );
        flashHandler.quoteClosePosition(invalidTokenId, 0);
    }

    // ============ SLIPPAGE PROTECTION TESTS ============

    function test_increasePositionExposure_slippageProtection() public {
        // Increase slippage to high level
        satsumaMock.setSlippageAndFees(0.1 ether); // 10% slippage

        uint256 msgValue = 5 ether;
        uint256 desiredCollateral = 10 ether; // > msgValue
        uint256 maxDebt = 330000 * UNIT; // Tight debt limit

        uint256 flashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (desiredCollateral - msgValue) / UNIT;
        (uint256 swapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(flashBorrowAmountWithFees, 0);
        uint256 expectedDebt = swapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT;

        // This should fail due to high slippage making the swap cost too much
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.MaxDebtExceeded.selector, expectedDebt, maxDebt)
        );
        flashHandler.increasePositionExposure{value: msgValue}(
            0,
            desiredCollateral,
            0.05 ether,
            maxDebt,
            user
        );
    }

    function test_flashClosePosition_slippageProtection() public {
        // Create position with normal slippage
        (uint256 tokenId,) = _createPosition(user, 1 ether, 2 ether);

        // Increase slippage significantly
        satsumaMock.setSlippageAndFees(0.2 ether); // 20% slippage

        // Authorize flash handler for repay and withdraw
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Withdraw);
        
        // Try to close with high minimum collateral out
        uint256 minCollateralOut = 0.99 ether; // Expecting 1% loss
        (uint256 actualCollateralOut,,) = flashHandler.quoteClosePosition(tokenId, 0);

        vm.startPrank(user);
            nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

            vm.expectRevert(
                abi.encodeWithSelector(
                    NectraFlashHandler.InsufficientCollateralOut.selector,
                    actualCollateralOut,
                    minCollateralOut
                )
            );
            flashHandler.flashClosePosition(tokenId, minCollateralOut, user);
        vm.stopPrank();
    }

    // ============ HELPER FUNCTIONS ============

    function test_getCBTCPrice() public view {
        uint256 price = flashHandler.getCBTCPrice();
        assertEq(price, BTC_PRICE, "Should return correct BTC price");
    }

    function test_getCBTCPrice_revertIfStale() public {
        oracle.setStale(true);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraFlashHandler.InvalidCBTCPrice.selector,
                BTC_PRICE,
                true
            )
        );
        flashHandler.getCBTCPrice();
    }

    // ============ EDGE CASE TESTS ============

    function test_increasePositionExposure_revertIfInvalidPositionId() public {
        uint256 invalidTokenId = 999;
        uint256 maxDebt = BTC_PRICE * (UNIT + cargs.openFeePercentage + cargs.flashBorrowFee + dexFeesAndSlippage) / UNIT;

        vm.startPrank(user);
            vm.expectRevert(
                abi.encodeWithSelector(NectraFlashHandler.InvalidPositionId.selector, invalidTokenId)
            );
            flashHandler.increasePositionExposure{value: 1 ether}(
                invalidTokenId,
                2 ether,
                0.05 ether,
                maxDebt,
                user
            );
        vm.stopPrank();
    }

    function test_quoteClosePosition_revertIfInvalidPositionId() public {
        uint256 invalidTokenId = 999;

        vm.startPrank(user);
            // Revert if tokenId is 0
            vm.expectRevert(
                abi.encodeWithSelector(NectraFlashHandler.InvalidPositionId.selector, 0)
            );
            flashHandler.quoteClosePosition(
                0,
                0
            );

            // Revert if tokenId is invalid
            vm.expectRevert(
                abi.encodeWithSelector(NectraFlashHandler.InvalidPositionId.selector, invalidTokenId)
            );
            flashHandler.quoteClosePosition(
                invalidTokenId,
                0
            );
        vm.stopPrank();
    }

    function test_receiveFunction_revertIfUnexpectedAmount() public {
        // The receive function should only accept expected amounts during operations
        vm.expectRevert(
            abi.encodeWithSelector(NectraFlashHandler.InvalidAmount.selector, 1 ether, 0)
        );
        payable(address(flashHandler)).transfer(1 ether);
    }

    // ============ INTEGRATION TESTS ============

    function test_fullLeverageLifecycle() public {
        // 1. Create leveraged position
        uint256 initialCollateral = 5 ether;
        uint256 desiredCollateral = 10 ether;
        (uint256 tokenId, uint256 maxDebt) = _createPosition(user, initialCollateral, desiredCollateral);

        // Verify position created
        (uint256 collateral1, uint256 debt1,) = nectraExternal.getPosition(tokenId);
        assertEq(collateral1, 10 ether, "Should have 10 cBTC collateral");
        assertLe(debt1, maxDebt, "Should have correct debt");

        // 2. Increase leverage - authorize flash handler
        uint256 permissionBitmask = 1 << uint256(NectraNFT.Permission.Deposit);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Borrow);

        vm.prank(user);
        nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

        uint256 extraCollateral = 2 ether;
        uint256 newDesiredCollateral = 15 ether;
        uint256 newFlashBorrowAmountWithFees = (UNIT + cargs.flashBorrowFee) * (newDesiredCollateral - desiredCollateral - extraCollateral) / UNIT;
        (uint256 AdditionalSwapAmountIn, ) = satsumaHandler.getNUSDToWCBTCExactOutputQuote(newFlashBorrowAmountWithFees, 0);
        uint256 newMaxDebt = AdditionalSwapAmountIn * (UNIT + cargs.openFeePercentage) / UNIT + debt1;

        vm.prank(user);
        flashHandler.increasePositionExposure{value: extraCollateral}(
            tokenId,
            newDesiredCollateral,
            0.05 ether,
            newMaxDebt,
            user
        );

        // Verify position increased
        (uint256 collateral2, uint256 debt2,) = nectraExternal.getPosition(tokenId);
        assertEq(collateral2, 15 ether, "Should have 15 cBTC collateral");
        assertTrue(debt2 > debt1, "Debt should have increased");

        // 3. Close position - authorize flash handler for closing
        permissionBitmask = 1 << uint256(NectraNFT.Permission.Repay);
        permissionBitmask |= 1 << uint256(NectraNFT.Permission.Withdraw);
        vm.prank(user);
        nectraNFT.authorize(tokenId, address(flashHandler), permissionBitmask);

        uint256 totalDebtCost = debt2 * (UNIT + cargs.flashMintFee) / UNIT;
        (uint256 swapAmountIn, ) = satsumaHandler.getWCBTCToNUSDExactOutputQuote(totalDebtCost, 0);
        uint256 minCollateralOut = desiredCollateral - swapAmountIn;

        vm.prank(user);
        uint256 collateralOut = flashHandler.flashClosePosition(
            tokenId,
            minCollateralOut,
            user
        );

        // Verify position closed and user received collateral
        (uint256 positionCollateral, uint256 positionDebt,) = nectraExternal.getPosition(tokenId);
        assertEq(positionCollateral, 0, "Position should be closed");
        assertEq(positionDebt, 0, "Position should be closed");
        
        uint256 reasonableCollateralOut = (initialCollateral + extraCollateral) * 0.97 ether / UNIT; // max 3% loss
        assertGe(collateralOut, reasonableCollateralOut, "Should receive reasonable collateral back");

        // Verify no tokens left in handler
        assertEq(address(flashHandler).balance, 0, "Handler should be clean");
        assertEq(nectraUSD.balanceOf(address(flashHandler)), 0, "Handler should be clean");
        assertEq(wcbtc.balanceOf(address(flashHandler)), 0, "Handler should be clean");
    }
}