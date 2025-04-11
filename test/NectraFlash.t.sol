// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraFlash} from "src/NectraFlash.sol";
import {ERC20} from "src/lib/ERC20.sol";
import {NectraBase} from "src/NectraBase.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

import {DEXMock} from "test/mocks/DEXMock.sol";

contract NectraFlashTest is NectraBaseTest {
    struct CallbackParams {
        bool leverageCallback;
        uint256 repayValueRatio;
        uint256 repayFeeRatio;
        bool returnValue;
        uint256 borrowAmount;
        uint256 usdBalanceBefore;
        uint256 btcBalanceBefore;
        bool reenter;
        bool enterOtherFlash;
        int256 debtDelta;
        int256 collateralDelta;
        uint256 addUSD; // Needed to get around that quoteModifyPosition reverts when flash borrow is in flight, so we need the debt/collateral diffs before we initiate flash functions
        uint256 addBTC;
    }

    CallbackParams internal callbackParams;
    DEXMock internal mockDex;
    uint256 internal tokenId;
    uint256 internal positionDebt = 10_000 ether;
    uint256 internal positionCollateral = 100_000 ether;
    uint256 internal interestRate = 0.05 ether;

    function setUp() public override {
        // cargs.feeRecipientAddress = makeAddr("feeRecipient");
        super.setUp();

        // Get some nUSD for flash fees and give nectra some cBTC to loan out
        int256 debtBeforeFee = int256(positionDebt * 1 ether / (1 ether + cargs.openFeePercentage)); // Debt before fee
        (tokenId,,,,) = nectra.modifyPosition{value: positionCollateral}(
            0, int256(positionCollateral), debtBeforeFee, interestRate, ""
        );
        uint256 expectedDebt = uint256(debtBeforeFee) + (uint256(debtBeforeFee) * cargs.openFeePercentage / 1 ether);
        _checkPosition(tokenId, positionCollateral, expectedDebt, interestRate);
        // Updated positionDebt to be exact amount in the position
        (, positionDebt) = nectraExternal.getPosition(tokenId);

        // Default callback params
        callbackParams = CallbackParams({
            leverageCallback: false,
            repayValueRatio: 1 ether,
            repayFeeRatio: 1 ether,
            returnValue: true,
            borrowAmount: positionCollateral > positionDebt ? positionDebt : positionCollateral,
            usdBalanceBefore: nectraUSD.balanceOf(address(this)),
            btcBalanceBefore: address(this).balance,
            reenter: false,
            enterOtherFlash: false,
            debtDelta: 0,
            collateralDelta: 0,
            addUSD: 0,
            addBTC: 0
        });

        mockDex = new DEXMock(address(nectraUSD), address(nectra), address(oracle));
        // Give mock DEX some cBTC to trade
        deal(address(mockDex), 10_000_000 ether);
    }

    //------------------------------------------------------------------------//
    // Flash Mint Tests
    //------------------------------------------------------------------------//
    function test_flashMintFeeCorrectlyChargedAndPaidToFeeRecipient() public {
        callbackParams.borrowAmount = 10_000 ether; // Borrow 10,000 nUSD
        bytes memory params = abi.encode(callbackParams);

        uint256 totalSupplyBefore = nectraUSD.totalSupply();
        uint256 feeRecipientBalanceBefore = nectraUSD.balanceOf(cargs.feeRecipientAddress);
        uint256 expectedFee = (callbackParams.borrowAmount * cargs.flashMintFee) / 1 ether;
        // Flash mint is permissionless and fee is paid to fee recipient
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);

        assertEq(
            nectraUSD.balanceOf(address(this)),
            callbackParams.usdBalanceBefore - expectedFee,
            "Contract balance should be balance before minus fee"
        );
        assertEq(
            nectraUSD.balanceOf(cargs.feeRecipientAddress),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient balance should be expected fee more than before"
        );
        assertEq(nectraUSD.totalSupply(), totalSupplyBefore, "Total supply should be the same as before");
    }

    function test_flashMintUnpaidLoanAndFeeReverts() public {
        assert(cargs.flashMintFee > 0);
        // Callback sets allowance at 50% of the loan
        callbackParams.repayValueRatio = 0.5 ether;
        bytes memory params = abi.encode(callbackParams);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);

        // Callback sets allowance at 100% of the loan
        callbackParams.repayValueRatio = 1 ether;
        // Callback sets allowance at 50% of the fee
        callbackParams.repayFeeRatio = 0.5 ether;
        params = abi.encode(callbackParams);

        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashMintRevertsIfCallbackReturnsFalse() public {
        callbackParams.returnValue = false;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraFlash.OperationFailed.selector);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashMintZeroAmountReverts() public {
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.flashMint(address(this), 0, "");
    }

    function test_flashMintReenterReverts() public {
        callbackParams.reenter = true;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.FlashMintInProgress.selector);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashMintFlashBorrowInProgressReverts() public {
        callbackParams.enterOtherFlash = true;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.FlashBorrowInProgress.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashMintCanRepayDebt() public {
        uint256 debtDiff = positionDebt / 10;
        callbackParams.debtDelta = -int256(debtDiff);
        (, int256 expectedDebtDiff,,) = nectra.quoteModifyPosition(tokenId, 0, callbackParams.debtDelta, interestRate);
        callbackParams.borrowAmount = uint256(-expectedDebtDiff);
        callbackParams.addUSD = uint256(-expectedDebtDiff);
        bytes memory params = abi.encode(callbackParams);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);

        // Check that the debt has been repaid
        _checkPosition(tokenId, positionCollateral, positionDebt - debtDiff, interestRate);
    }

    //------------------------------------------------------------------------//
    // Flash Borrow Tests
    //------------------------------------------------------------------------//
    function test_flashBorrowSimple() public {
        callbackParams.borrowAmount = positionCollateral / 10;
        bytes memory params = abi.encode(callbackParams);

        uint256 expectedFee = (callbackParams.borrowAmount * cargs.flashBorrowFee) / 1 ether;
        // Flash borrow is permissionless
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
        assertEq(
            address(this).balance,
            callbackParams.btcBalanceBefore - expectedFee,
            "Contract balance should be balance before minus fee"
        );
    }

    function test_flashBorrowCanBorrowUptoNectraBalance() public {
        // Borrow more than Nectra's cBTC balance
        callbackParams.borrowAmount = address(nectra).balance + 1;
        bytes memory params = abi.encode(callbackParams);
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);

        // Borrow all of Nectra's cBTC balance
        callbackParams.borrowAmount = address(nectra).balance;
        params = abi.encode(callbackParams);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashBorrowRevertsIfCallbackReturnsFalse() public {
        callbackParams.returnValue = false;
        bytes memory params = abi.encode(callbackParams);
        vm.expectRevert(NectraFlash.OperationFailed.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashBorrowtZeroAmountReverts() public {
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.flashBorrow(address(this), 0, "");
    }

    function test_flashBorrowReenterReverts() public {
        callbackParams.reenter = true;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.FlashBorrowInProgress.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashBorrowFlashMintInProgressReverts() public {
        callbackParams.enterOtherFlash = true;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.FlashMintInProgress.selector);
        nectra.flashMint(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashBorrowUnpaidLoanAndFeeReverts() public {
        assert(cargs.flashBorrowFee > 0);
        // Callback pays 50% of the loan
        callbackParams.repayValueRatio = 0.5 ether;
        bytes memory params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);

        // Callback pays 100% of the loan
        callbackParams.repayValueRatio = 1 ether;
        // Callback pays 50% of the fee
        callbackParams.repayFeeRatio = 0.5 ether;
        params = abi.encode(callbackParams);

        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);
    }

    function test_flashBorrowPaysCorrectFeeToTreasury() public {
        callbackParams.borrowAmount = positionCollateral / 10;
        bytes memory params = abi.encode(callbackParams);
        uint256 treasuryBalanceBefore = cargs.feeRecipientAddress.balance;
        uint256 expectedFee = (callbackParams.borrowAmount * cargs.flashBorrowFee) / 1 ether;

        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);

        assertEq(
            cargs.feeRecipientAddress.balance,
            treasuryBalanceBefore + expectedFee,
            "Treasury balance should be balance before plus expected fee"
        );
    }

    function test_flashBorrowRepayFlashBorrowOnlyAcceptsValueInFlashBorrow() public {
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.repayFlashBorrow{value: 1 ether}();
    }

    // TODO: making this compile by forcing ints but the values are now supposed to be deltas not absolute so it will fail
    function test_flashBorrowCanBeUsedForCollateral() public {
        // Borrow all of Nectra's cBTC balance
        callbackParams.borrowAmount = address(nectra).balance;
        callbackParams.collateralDelta = int256(callbackParams.borrowAmount);
        callbackParams.addBTC = uint256(callbackParams.borrowAmount);
        bytes memory params = abi.encode(callbackParams);

        uint256 expectedFee = (callbackParams.borrowAmount * cargs.flashBorrowFee) / 1 ether;
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);

        assertEq(
            address(this).balance,
            callbackParams.btcBalanceBefore - callbackParams.borrowAmount - expectedFee,
            "Contract balance should be balance before minus borrowed amount minus fee"
        );
        _checkPosition(tokenId, positionCollateral + callbackParams.borrowAmount, positionDebt, interestRate);
    }

    function test_flashBorrowDoesNotImpactSystemCRatio() public {
        // Borrow all of Nectra's cBTC balance
        callbackParams.borrowAmount = address(nectra).balance;
        callbackParams.collateralDelta = int256(callbackParams.borrowAmount);
        (uint256 price,) = oracle.getLatestPrice();
        // Borrow the max amount. Technically this should be possible but because system collaterization
        // check no longer takes into account borrowed collateral, this will fail as system collateral
        // will be half what it should be since loan hasn't been repaid
        uint256 newPositionCollateral = positionCollateral + callbackParams.borrowAmount;
        uint256 newPositionDebt = newPositionCollateral * price / cargs.issuanceRatio;
        callbackParams.debtDelta =
            int256((newPositionDebt - positionDebt) * 1 ether / (1 ether + cargs.openFeePercentage)); // Debt delta before fee
        vm.expectRevert(NectraBase.InsufficientCollateral.selector);
        nectra.quoteModifyPosition(tokenId, callbackParams.collateralDelta, callbackParams.debtDelta, interestRate);

        // We should be able to borrow the max amount of debt allowed by the current system collateral balance
        newPositionDebt = callbackParams.borrowAmount * price / cargs.issuanceRatio;
        callbackParams.debtDelta =
            int256((newPositionDebt - positionDebt) * 1 ether / (1 ether + cargs.openFeePercentage)); // Debt delta before fee
        callbackParams.addBTC = uint256(callbackParams.borrowAmount);
        bytes memory params = abi.encode(callbackParams);
        nectra.flashBorrow(address(this), callbackParams.borrowAmount, params);

        // Expected position debt will be the delta plus the open fee
        uint256 expectedDebt =
            uint256(callbackParams.debtDelta) + (uint256(callbackParams.debtDelta) * cargs.openFeePercentage / 1 ether);
        _checkPosition(
            tokenId, positionCollateral + callbackParams.borrowAmount, positionDebt + expectedDebt, interestRate
        );
        assertEq(
            address(nectra).balance,
            callbackParams.borrowAmount * 2,
            "Contract cBTC balance should be equal to twice borrowed amount after flash borrow"
        );
    }

    function test_flashBorrowCanBeUsedForLeverage() public {
        // Set oracle price to 2 to simplify things
        uint256 price = 2 ether; // 1 cBTC = $2
        oracle.setCurrentPrice(price);

        // Initial state
        uint256 initialCBTCBalance = address(this).balance;
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        // 50 cBTC ($100) of our own collateral
        uint256 ourCollateral = 50 ether;
        // Borrow 100 cBTC ($200) of borrowed collateral
        callbackParams.borrowAmount = 100 ether;
        // New collateral is 150 cBTC ($300)
        uint256 newPositionCollateral = ourCollateral + callbackParams.borrowAmount;
        callbackParams.collateralDelta = int256(newPositionCollateral);
        // New debt ~$214. Calc takes into account opening fee since this is now part of the cratio i.e. what is the max debt delta we can take such that we are at issuance given the a realized opening fee
        callbackParams.debtDelta = int256(
            (newPositionCollateral * price * 1 ether) / (cargs.issuanceRatio * (1 ether + cargs.openFeePercentage))
        );
        // Use leverage callback
        callbackParams.leverageCallback = true;

        nectra.flashBorrow(address(this), callbackParams.borrowAmount, abi.encode(callbackParams));

        assertEq(
            address(this).balance,
            initialCBTCBalance - ourCollateral,
            "Contract cBTC balance should be reduced by only our collateral amount"
        );
        assertGt(
            nectraUSD.balanceOf(address(this)),
            initialNUSDBalance,
            "Contract nUSD balance should be slightly greater than before"
        );
        assertApproxEqRel(
            nectraUSD.balanceOf(address(this)),
            initialNUSDBalance,
            1e16,
            "Contract nUSD balance should be approximately equal to initial nUSD balance as all USD was used for leverage"
        );

        // Expected position debt will be the delta plus the open fee
        uint256 expectedDebt =
            uint256(callbackParams.debtDelta) + (uint256(callbackParams.debtDelta) * cargs.openFeePercentage / 1 ether);
        _checkPosition(tokenId, newPositionCollateral, expectedDebt, interestRate);
    }

    function test_mockDex() public {
        // Initial cBTC balance for Alice
        uint256 initialCBTCBalance = 10_000 ether;
        address alice = makeAddr("alice");
        vm.deal(alice, initialCBTCBalance);
        (uint256 price,) = oracle.getLatestPrice();

        // Alice wants to sell 5,000 cBTC
        uint256 amountToSell = 5_000 ether;
        vm.prank(alice);
        uint256 nUSDAmount = mockDex.sellBTC{value: amountToSell}(amountToSell);

        assertEq(nectraUSD.balanceOf(alice), nUSDAmount, "Alice should receive the correct amount of nUSD");
        assertEq(
            nUSDAmount,
            amountToSell * price / 1 ether,
            "Alice should receive the correct amount of nUSD based on the price"
        );
        assertEq(
            address(alice).balance,
            initialCBTCBalance - amountToSell,
            "Alice's cBTC balance should be correct after selling BTC"
        );

        // Alice wants to buy 2,500 cBTC
        uint256 amountToBuy = 2_500 ether;
        vm.prank(alice);
        nectraUSD.approve(address(mockDex), type(uint256).max);

        vm.prank(alice);
        uint256 cBTCAmount = mockDex.buyBTC(amountToBuy);

        assertEq(
            address(alice).balance,
            initialCBTCBalance - amountToSell + cBTCAmount,
            "Alice's cBTC balance should be correct after buying BTC"
        );
        assertEq(
            nectraUSD.balanceOf(alice),
            nUSDAmount - (cBTCAmount * price / 1 ether),
            "Alice should have the correct amount of nUSD after buying BTC"
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata encodedParams
    ) external payable returns (bool) {
        CallbackParams memory params = abi.decode(encodedParams, (CallbackParams));
        if (params.leverageCallback) {
            return _leverageCallback(asset, amount, premium, initiator, encodedParams);
        } else {
            return _genericCallback(asset, amount, premium, initiator, encodedParams);
        }
    }

    function _genericCallback(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata encodedParams
    ) internal returns (bool) {
        assertEq(initiator, address(this));

        CallbackParams memory params = abi.decode(encodedParams, (CallbackParams));
        assertEq(amount, params.borrowAmount, "Borrow amount passed should be equal to params borrow amount");

        uint256 repayValue = amount * params.repayValueRatio / 1 ether;
        uint256 repayFee = premium * params.repayFeeRatio / 1 ether;

        // Flash mint
        if (asset == address(nectraUSD)) {
            if (params.reenter) {
                nectra.flashMint(address(this), params.borrowAmount, encodedParams);
            }
            if (params.enterOtherFlash) {
                nectra.flashBorrow(address(this), params.borrowAmount, encodedParams);
            }
            assertEq(msg.value, 0, "cBTC value should be 0");
            assertEq(address(this).balance, params.btcBalanceBefore, "Contract cBTC balance should be balance before");
            assertEq(
                nectraUSD.balanceOf(address(this)),
                params.usdBalanceBefore + params.borrowAmount,
                "Contract nUSD balance should be balance before plus borrow amount"
            );

            _checkAndModifyPositionWithBorrowedAmounts(
                params.collateralDelta, params.debtDelta, amount, 0, params.addUSD, params.addBTC
            );

            // Repay loan + fee
            if (params.returnValue) {
                nectraUSD.approve(address(nectra), repayValue + repayFee);
                return true;
            } else {
                return false;
            }
        }
        // Flash borrow
        else if (asset == address(0)) {
            if (params.reenter) {
                nectra.flashBorrow(address(this), params.borrowAmount, encodedParams);
            }
            if (params.enterOtherFlash) {
                nectra.flashMint(address(this), params.borrowAmount, encodedParams);
            }

            assertEq(
                nectraUSD.balanceOf(address(this)),
                params.usdBalanceBefore,
                "Contract nUSD balance should be balance before"
            );
            assertEq(msg.value, amount, "cBTC value should be equal to borrow amount");
            assertEq(
                address(this).balance,
                params.btcBalanceBefore + params.borrowAmount,
                "Contract balance should be balance before plus borrow amount"
            );

            _checkAndModifyPositionWithBorrowedAmounts(
                params.collateralDelta, params.debtDelta, 0, amount, params.addUSD, params.addBTC
            );

            // Repay loan + fee
            if (params.returnValue) {
                nectra.repayFlashBorrow{value: repayValue + repayFee}();
                return true;
            } else {
                return false;
            }
        } else {
            revert("Invalid asset address");
        }
    }

    function _leverageCallback(address, uint256 amount, uint256 premium, address, bytes calldata encodedParams)
        internal
        returns (bool)
    {
        CallbackParams memory params = abi.decode(encodedParams, (CallbackParams));
        // Create new position with borrowed amounts and passed debt value
        int256 debtDiff;
        (tokenId,, debtDiff,,) = nectra.modifyPosition{value: uint256(params.collateralDelta)}(
            0, params.collateralDelta, params.debtDelta, interestRate, ""
        );

        // Swap the received nUSD for cBTC
        nectraUSD.approve(address(mockDex), uint256(debtDiff)); // Approve mock DEX to spend nUSD
        uint256 btcAmount = mockDex.buyBTC(amount + premium); // Buy cBTC with the borrowed nUSD
        nectra.repayFlashBorrow{value: btcAmount}(); // Repay the flash borrow
        return true;
    }

    function _checkAndModifyPositionWithBorrowedAmounts(
        int256 collateralDelta,
        int256 debtDelta,
        uint256 borrowedUsd,
        uint256 borrowedBTC,
        uint256 addUSD,
        uint256 addBTC
    ) internal {
        if (collateralDelta != 0 || debtDelta != 0) {
            if (addUSD > 0) {
                if (addUSD > borrowedUsd) {
                    revert("Cannot repay more than borrowed amount");
                }
                nectraUSD.approve(address(nectra), addUSD);
            }

            if (addBTC > 0) {
                if (addBTC > borrowedBTC) {
                    revert("Cannot add more collateral than borrowed amount");
                }
                nectra.modifyPosition{value: addBTC}(tokenId, collateralDelta, debtDelta, interestRate, "");
            } else {
                nectra.modifyPosition(tokenId, collateralDelta, debtDelta, interestRate, "");
            }
        }
    }
}
