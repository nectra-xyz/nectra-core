// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest, console2} from "test/redeem/NectraRedeemBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraBase} from "src/NectraBase.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemTest is NectraRedeemBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_should_fail_when_redeeming_during_flash_mint() public {
        vm.expectRevert();
        nectra.flashMint(address(this), 10 ether, "");
    }

    function test_should_fail_when_redeeming_during_flash_borrow() public {
        vm.expectRevert();
        nectra.flashBorrow(address(this), 1 ether, "");
    }

    function test_should_fail_when_redeeming_with_min_amount_out_too_low() public {
        uint256 expectedAmountOut = 8.333333333333333333 ether; // 10 / 1.2
        vm.expectRevert(abi.encodeWithSelector(NectraRedeem.MinAmountOutNotMet.selector, expectedAmountOut, 100 ether));
        nectra.redeem(10 ether, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(NectraRedeem.MinAmountOutNotMet.selector, expectedAmountOut, 10 ether));
        nectra.redeem(10 ether, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(NectraRedeem.MinAmountOutNotMet.selector, expectedAmountOut, 8.33333333333334 ether)
        );
        nectra.redeem(10 ether, 8.33333333333334 ether);

        nectra.redeem(10 ether, 8.33333333333333 ether);
    }

    function test_redeem_should_fail_if_oracle_is_nonexistant_or_stale() public {
        if (address(oracle) == address(0)) revert();
        oracle.setStale(true);
        vm.expectRevert(NectraBase.InvalidCollateralPrice.selector);
        nectra.redeem(10 ether, 0);
    }

    function test_should_fail_when_redeeming_zero_amount() public {
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.redeem(0, 0);
    }

    function test_redemptions_are_permisionless() public {
        address randomUser = makeAddr("RaNDoMUsEr1234");
        nectraUSD.transfer(randomUser, 2 ether);

        vm.startPrank(randomUser);
        nectraUSD.approve(address(nectra), 2 ether);
        nectra.redeem(1 ether, 0 ether);
        vm.stopPrank();
    }

    function test_redemptions_should_apply_interest_to_buckets() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);

        nectra.redeem(10 ether, 0 ether);

        // 45 * math.exp(math.log(1 + 0.05) * 31 / 365) - 10
        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 35.18685888491587 ether, 1e11);
    }

    function test_redemption_burns_nusd_from_caller() public {
        uint256 redeemAmount = 10 ether;
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialTotalSupply = nectraUSD.totalSupply();

        nectraUSD.approve(address(nectra), redeemAmount);
        nectra.redeem(redeemAmount, 0);

        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 finalTotalSupply = nectraUSD.totalSupply();

        assertEq(initialNUSDBalance - finalNUSDBalance, redeemAmount, "Incorrect amount of nUSD burned from caller");
        assertEq(
            initialTotalSupply - finalTotalSupply, redeemAmount, "Incorrect amount of nUSD burned from total supply"
        );
    }

    function test_redemption_reduces_bucket_debt_by_burned_nusd() public {
        uint256 LOW_RATE = 0.05 ether;
        uint256 redeemAmount = 10 ether;

        uint256 initialBucketDebt = nectraExternal.getBucketDebt(LOW_RATE);
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialTotalSupply = nectraUSD.totalSupply();

        nectraUSD.approve(address(nectra), redeemAmount);
        nectra.redeem(redeemAmount, 0);

        uint256 finalBucketDebt = nectraExternal.getBucketDebt(LOW_RATE);
        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 finalTotalSupply = nectraUSD.totalSupply();

        uint256 burnedNUSD = initialNUSDBalance - finalNUSDBalance;
        uint256 reducedBucketDebt = initialBucketDebt - finalBucketDebt;

        assertEq(burnedNUSD, reducedBucketDebt, "Bucket debt reduction should match burned nUSD");
        assertEq(burnedNUSD, initialTotalSupply - finalTotalSupply, "Total supply reduction should match burned nUSD");
        assertEq(burnedNUSD, redeemAmount, "Burned nUSD should match redemption amount");
    }

    function test_redemption_fee_is_zero_when_base_fee_and_scalar_are_zero() public {
        assertEq(cargs.redemptionBaseFee, 0, "Redemption base fee should be 0");
        assertEq(cargs.redemptionDynamicFeeScalar, 0, "Redemption dynamic fee scalar should be 0");

        uint256 redeemAmount = 10 ether;
        uint256 redemptionFee = nectra.getRedemptionFee(redeemAmount);

        assertEq(redemptionFee, 0, "Redemption fee should be 0 when base fee is 0");

        uint256 initialBalance = address(this).balance;
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        uint256 collateralRedeemed = nectra.redeem(redeemAmount, 0);

        uint256 finalBalance = address(this).balance;
        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));

        assertEq(redemptionFee, 0, "Redemption fee should still be 0 after redemption");
        assertEq(finalNUSDBalance, initialNUSDBalance - redeemAmount, "Incorrect nUSD burned");
        assertEq(finalBalance - initialBalance, collateralRedeemed, "Incorrect collateral received");
    }

    function test_redemption_fails_when_amount_smaller_than_fee() public {
        uint256 smallDebtAmount = 0.1 ether;
        uint256 collateralAmount = 1 ether;

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: collateralAmount}(
            0, int256(collateralAmount), int256(smallDebtAmount), 0.005 ether, ""
        );

        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialETHBalance = address(this).balance;
        uint256 initialFeeRecipientBalance = address(cargs.feeRecipientAddress).balance;

        nectraUSD.approve(address(nectra), smallDebtAmount);

        vm.expectRevert();
        nectra.redeem(0.000000000000000001 ether, 0);

        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 finalETHBalance = address(this).balance;
        uint256 finalFeeRecipientBalance = address(cargs.feeRecipientAddress).balance;
        (, uint256 finalDebt) = nectraExternal.getPosition(tokenId);

        assertEq(finalNUSDBalance, initialNUSDBalance, "NUSD balance should not change");
        assertEq(finalETHBalance, initialETHBalance, "ETH balance should not change");
        assertEq(finalFeeRecipientBalance, initialFeeRecipientBalance, "Fee recipient balance should not change");
        assertEq(finalDebt, smallDebtAmount, "Position debt should not change");
        assertEq(nectraExternal.getBucketDebt(0.005 ether), smallDebtAmount, "Bucket debt should not change");
    }

    function test_should_fail_if_trying_to_redeem_more_than_global_debt() public {
        uint256 startingInterestRate = 0.2 ether;
        for (uint256 i = 0; i < 100; i++) {
            nectra.modifyPosition{value: 1 ether}(0, 1 ether, 0.2 ether, startingInterestRate, "");
            startingInterestRate += cargs.interestRateIncrement;
        }
        vm.expectRevert();
        nectra.redeem(160 ether + 1 wei, 0);
    }

    function test_findFirstSet_bucket_selection_adjacent() public {
        uint256 LOW_INTEREST_RATE = 0.005 ether;
        uint256 VERY_LOW_MID_RATE = 0.006 ether;
        uint256 MID_INTEREST_RATE = 0.007 ether;
        uint256 HIGH_INTEREST_RATE = 0.008 ether;

        uint256 tokenIdLow;
        uint256 tokenIdMid;
        uint256 tokenIdHigh;

        (tokenIdLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, LOW_INTEREST_RATE, "");
        (tokenIdMid,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, MID_INTEREST_RATE, "");
        (tokenIdHigh,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, HIGH_INTEREST_RATE, "");

        uint256 initialLowBucketDebt = nectraExternal.getBucketDebt(LOW_INTEREST_RATE);
        uint256 initialMidBucketDebt = nectraExternal.getBucketDebt(MID_INTEREST_RATE);
        uint256 initialHighBucketDebt = nectraExternal.getBucketDebt(HIGH_INTEREST_RATE);

        deal(address(nectraUSD), address(this), 100 ether);
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(30 ether, 0);

        assertEq(nectraExternal.getBucketDebt(LOW_INTEREST_RATE), 0, "Lowest bucket should be empty");
        assertEq(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE), initialMidBucketDebt, "Mid bucket should be unchanged"
        );
        assertEq(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE), initialHighBucketDebt, "High bucket should be unchanged"
        );

        nectra.redeem(10 ether, 0);

        assertEq(nectraExternal.getBucketDebt(LOW_INTEREST_RATE), 0, "Lowest bucket should remain empty");
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE),
            initialMidBucketDebt - 10 ether,
            1e11,
            "Mid bucket should be reduced"
        );
        assertEq(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE),
            initialHighBucketDebt,
            "High bucket should still be unchanged"
        );

        uint256 tokenIdVeryLowMid;
        (tokenIdVeryLowMid,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 25 ether, VERY_LOW_MID_RATE, "");

        nectra.redeem(15 ether, 0);

        uint256 veryLowMidBucketDebt = nectraExternal.getBucketDebt(VERY_LOW_MID_RATE);
        assertApproxEqRel(veryLowMidBucketDebt, 10 ether, 1e11, "1% bucket should be partially redeemed");
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE), 20 ether, 1e11, "2% bucket should remain unchanged"
        );

        uint256 tokenIdNewLow;
        (tokenIdNewLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 20 ether, LOW_INTEREST_RATE, "");

        nectra.redeem(10 ether, 0);

        assertApproxEqRel(
            nectraExternal.getBucketDebt(LOW_INTEREST_RATE),
            10 ether,
            1e11,
            "New 0.5% bucket should be partially redeemed"
        );
        assertApproxEqRel(
            nectraExternal.getBucketDebt(VERY_LOW_MID_RATE), 10 ether, 1e11, "1% bucket should remain unchanged"
        );
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE), 20 ether, 1e11, "2% bucket should remain unchanged"
        );

        (, uint256 lowPositionDebt) = nectraExternal.getPosition(tokenIdLow);
        (, uint256 veryLowMidPositionDebt) = nectraExternal.getPosition(tokenIdVeryLowMid);
        (, uint256 midPositionDebt) = nectraExternal.getPosition(tokenIdMid);
        (, uint256 highPositionDebt) = nectraExternal.getPosition(tokenIdHigh);
        (, uint256 newLowPositionDebt) = nectraExternal.getPosition(tokenIdNewLow);

        assertEq(lowPositionDebt, 0, "Original low interest position should be fully redeemed");
        assertApproxEqRel(veryLowMidPositionDebt, 10 ether, 1e11, "Very low mid position should be partially redeemed");
        assertApproxEqRel(midPositionDebt, 20 ether, 1e11, "Mid interest position should be partially redeemed");
        assertEq(highPositionDebt, 30 ether, "High interest position should be unchanged");
        assertApproxEqRel(newLowPositionDebt, 10 ether, 1e11, "New low interest position should be partially redeemed");
    }

    function test_findFirstSet_bucket_selection_sparse() public {
        uint256 LOW_INTEREST_RATE = 0.005 ether;
        uint256 VERY_LOW_MID_RATE = 0.01 ether;
        uint256 MID_INTEREST_RATE = 0.025 ether;
        uint256 HIGH_INTEREST_RATE = 0.049 ether;

        uint256 tokenIdLow;
        uint256 tokenIdMid;
        uint256 tokenIdHigh;

        (tokenIdLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, LOW_INTEREST_RATE, "");
        (tokenIdMid,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, MID_INTEREST_RATE, "");
        (tokenIdHigh,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, HIGH_INTEREST_RATE, "");

        uint256 initialLowBucketDebt = nectraExternal.getBucketDebt(LOW_INTEREST_RATE);
        uint256 initialMidBucketDebt = nectraExternal.getBucketDebt(MID_INTEREST_RATE);
        uint256 initialHighBucketDebt = nectraExternal.getBucketDebt(HIGH_INTEREST_RATE);

        deal(address(nectraUSD), address(this), 100 ether);
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(30 ether, 0);

        assertEq(nectraExternal.getBucketDebt(LOW_INTEREST_RATE), 0, "Lowest bucket should be empty");
        assertEq(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE), initialMidBucketDebt, "Mid bucket should be unchanged"
        );
        assertEq(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE), initialHighBucketDebt, "High bucket should be unchanged"
        );
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 redeemAmount = 10 ether;
        nectra.redeem(redeemAmount, redeemAmount.divWad(collateralPrice));

        assertEq(nectraExternal.getBucketDebt(LOW_INTEREST_RATE), 0, "Lowest bucket should remain empty");
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE),
            initialMidBucketDebt - 10 ether,
            1e11,
            "Mid bucket should be reduced"
        );
        assertEq(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE),
            initialHighBucketDebt,
            "High bucket should still be unchanged"
        );

        uint256 tokenIdVeryLowMid;
        (tokenIdVeryLowMid,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 25 ether, VERY_LOW_MID_RATE, "");

        nectra.redeem(15 ether, 0);

        uint256 veryLowMidBucketDebt = nectraExternal.getBucketDebt(VERY_LOW_MID_RATE);
        assertApproxEqRel(veryLowMidBucketDebt, 10 ether, 1e11, "VERY_LOW_MID_RATE bucket should be partially redeemed");
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE),
            20 ether,
            1e11,
            "MID_INTEREST_RATE bucket should remain unchanged"
        );

        uint256 tokenIdNewLow;
        (tokenIdNewLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 20 ether, LOW_INTEREST_RATE, "");

        nectra.redeem(10 ether, 0);

        assertApproxEqRel(
            nectraExternal.getBucketDebt(LOW_INTEREST_RATE),
            10 ether,
            1e11,
            "New 0.5% bucket should be partially redeemed"
        );
        assertApproxEqRel(
            nectraExternal.getBucketDebt(VERY_LOW_MID_RATE), 10 ether, 1e11, "1% bucket should remain unchanged"
        );
        assertApproxEqRel(
            nectraExternal.getBucketDebt(MID_INTEREST_RATE), 20 ether, 1e11, "2% bucket should remain unchanged"
        );

        (, uint256 lowPositionDebt) = nectraExternal.getPosition(tokenIdLow);
        (, uint256 veryLowMidPositionDebt) = nectraExternal.getPosition(tokenIdVeryLowMid);
        (, uint256 midPositionDebt) = nectraExternal.getPosition(tokenIdMid);
        (, uint256 highPositionDebt) = nectraExternal.getPosition(tokenIdHigh);
        (, uint256 newLowPositionDebt) = nectraExternal.getPosition(tokenIdNewLow);

        assertEq(lowPositionDebt, 0, "Original low interest position should be fully redeemed");
        assertApproxEqRel(veryLowMidPositionDebt, 10 ether, 1e11, "Very low mid position should be partially redeemed");
        assertApproxEqRel(midPositionDebt, 20 ether, 1e11, "Mid interest position should be partially redeemed");
        assertEq(highPositionDebt, 30 ether, "High interest position should be unchanged");
        assertApproxEqRel(newLowPositionDebt, 10 ether, 1e11, "New low interest position should be partially redeemed");
    }

    function test_findFirstSet_bucket_selection_close_position_and_remove_bucket() public {
        uint256 LOW_INTEREST_RATE = 0.005 ether;
        uint256 HIGH_INTEREST_RATE = 0.049 ether;

        uint256 tokenIdLow;
        uint256 tokenIdMid;
        uint256 tokenIdHigh;

        (tokenIdLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, LOW_INTEREST_RATE, "");
        (tokenIdHigh,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, HIGH_INTEREST_RATE, "");

        uint256 initialLowBucketDebt = nectraExternal.getBucketDebt(LOW_INTEREST_RATE);
        uint256 initialHighBucketDebt = nectraExternal.getBucketDebt(HIGH_INTEREST_RATE);

        deal(address(nectraUSD), address(this), 100 ether);
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(1 ether, 0);

        assertEq(
            nectraExternal.getBucketDebt(LOW_INTEREST_RATE), 29 ether, "Lowest bucket should be partially redeemed"
        );
        assertEq(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE), initialHighBucketDebt, "High bucket should be unchanged"
        );

        nectra.modifyPosition(tokenIdLow, type(int256).min, type(int256).min, LOW_INTEREST_RATE, "");

        nectra.redeem(1 ether, 0);

        uint256 lowBucketDebt = nectraExternal.getBucketDebt(LOW_INTEREST_RATE);
        assertEq(lowBucketDebt, 0, "Lowest bucket should be empty");
        assertApproxEqRel(
            nectraExternal.getBucketDebt(HIGH_INTEREST_RATE),
            initialHighBucketDebt - 1 ether,
            1e11,
            "High bucket should be less 1 ether"
        );
    }

    function test_self_redemption_at_lowest_rate_should_not_be_profitable() public {
        uint256 LOWEST_INTEREST_RATE = 0.005 ether;
        uint256 collateralAmount = 100 ether;
        uint256 debtAmount = 50 ether;

        uint256 initialETHBalance = address(this).balance;
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: collateralAmount}(
            0, int256(collateralAmount), int256(debtAmount), LOWEST_INTEREST_RATE, ""
        );

        uint256 postPositionETHBalance = address(this).balance;
        uint256 postPositionNUSDBalance = nectraUSD.balanceOf(address(this));

        (uint256 positionCollateral, uint256 positionDebt) = nectraExternal.getPosition(tokenId);
        assertEq(positionCollateral, collateralAmount, "Incorrect collateral amount");
        assertEq(positionDebt, debtAmount, "Incorrect debt amount");

        nectraUSD.approve(address(nectra), debtAmount);

        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralWithoutFees = debtAmount.divWad(collateralPrice);

        // Can't redeem 100% of the debt due to redemption slippage check
        uint256 actualCollateralRedeemed = nectra.redeem(debtAmount - 1 wei, 0);

        uint256 finalETHBalance = address(this).balance;
        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));

        uint256 ethSpent = initialETHBalance - postPositionETHBalance;
        uint256 ethReceived = finalETHBalance - postPositionETHBalance;
        uint256 nusdReceived = postPositionNUSDBalance - initialNUSDBalance;
        uint256 nusdSpent = postPositionNUSDBalance - finalNUSDBalance;

        assertEq(
            actualCollateralRedeemed,
            expectedCollateralWithoutFees - 1 wei,
            "Redemption should result in same collateral as raw conversion due to no fees"
        );

        assertTrue(ethReceived < ethSpent, "Should not receive more ETH than initially deposited");

        uint256 ethLoss = ethSpent - ethReceived;

        (uint256 finalCollateral, uint256 finalDebt) = nectraExternal.getPosition(tokenId);
        // Due to redeeming 1 wei less and debt rounding 1 wei up, expected remaining debt of 2 wei
        assertEq(finalDebt, 2, "Position should have no remaining debt");
        assertApproxEqRel(
            finalCollateral, collateralAmount - actualCollateralRedeemed, 1e11, "Incorrect remaining collateral"
        );
    }
}
