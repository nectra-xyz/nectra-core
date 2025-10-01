// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RedeemBaseTest, console2} from "test/redeem-basic/RedeemBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraBase} from "src/NectraBase.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemTest is RedeemBaseTest {
    using FixedPointMathLib for uint256;

    uint256 defaultInterestRate = 0.05 ether;

    function setUp() public virtual override {
        super.setUp();

        nectra.storeSystemInterestRate(defaultInterestRate);
    }

    function test_redeem_ShouldFailWhenRedeemingDuringFlashMint() public {
        vm.expectRevert();
        nectra.flashMint(address(this), 10 ether, "");
    }

    function test_redeem_ShouldFailWhenRedeemingDuringFlashBorrow() public {
        vm.expectRevert();
        nectra.flashBorrow(address(this), 1 ether, "");
    }

    function test_redeem_ShouldFailWhenRedeemingWithMinAmountOutTooLow() public {
        uint256 expectedAmountOut = 8.333333333333333331 ether; // 10 / 1.2
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

    function test_redeem_ShouldFailIfOracleIsNonexistantOrStale() public {
        if (address(oracle) == address(0)) revert();
        oracle.setStale(true);
        vm.expectRevert(NectraBase.InvalidCollateralPrice.selector);
        nectra.redeem(10 ether, 0);
    }

    function test_redeem_ShouldFailWhenRedeemingZeroAmount() public {
        vm.expectRevert(NectraBase.InvalidAmount.selector);
        nectra.redeem(0, 0);
    }

    function test_redeem_ShouldBePermisionless() public {
        address randomUser = makeAddr("RaNDoMUsEr1234");
        nectraUSD.transfer(randomUser, 2 ether);

        vm.startPrank(randomUser);
        nectraUSD.approve(address(nectra), 2 ether);
        nectra.redeem(1 ether, 0 ether);
        vm.stopPrank();
    }

    function test_redeem_ShouldApplyInterestToBuckets() public {
        // set system interest rate slightly higher than 0.05 ether
        nectra.storeSystemInterestRate(0.05 ether + systemParams.interestRateIncrement);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        nectra.redeem(10 ether, 0 ether);

        // 45 * math.exp(math.log(1 + 0.05) * 31 / 365) - 10
        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 35.18685888491587 ether, 1e11);
    }

    function test_redeem_ShouldBurnNUSDFromCaller() public {
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

    function test_redeem_ShouldReduceBucketDebtByBurnedNUSD() public {
        uint256 LOW_RATE = 0.05 ether;
        uint256 redeemAmount = 10 ether;

        uint256 initialBucketDebt = nectraExternal.getBucketDebt(LOW_RATE);
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialTotalSupply = nectraUSD.totalSupply();

        nectraUSD.approve(address(nectra), redeemAmount);

        // set system interest rate slightly higher than low rate
        nectra.storeSystemInterestRate(LOW_RATE + systemParams.interestRateIncrement);
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

    function test_redeem_ShouldHaveZeroRedemptionFeeWhenBaseFeeAndScalarAreZero() public {
        assertEq(systemParams.redemptionBaseFee, 0, "Redemption base fee should be 0");
        assertEq(systemParams.redemptionDynamicFeeScalar, 0, "Redemption dynamic fee scalar should be 0");

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

    function test_redeem_ShouldFailIfTryingToRedeemMoreThanGlobalDebt() public {
        uint256 startingInterestRate = 0.2 ether;
        for (uint256 i = 0; i < 100; i++) {
            nectra.storeSystemInterestRate(startingInterestRate);
            nectra.modifyPosition{value: 1 ether}(0, 1 ether, 0.2 ether, "");
            startingInterestRate += systemParams.interestRateIncrement;
        }
        vm.expectRevert();
        nectra.redeem(160 ether + 1 wei, 0);
    }

    function test_redeem_ShouldNotRedeemFromInsolventBucket() public {
        // collateral 100, debt = 5
        // 100 * 1.2 / 1.4 ~= 85

        nectra.storeSystemInterestRate(interestRates[2]);
        nectra.modifyPosition(tokens[2], 0, 80 ether, "");

        uint256 initialBucketDebt = nectraExternal.getBucketDebt(interestRates[2]);
        assertApproxEqRel(initialBucketDebt, 85 ether, 1e11, "Initial bucket debt should be 85 ether");

        oracle.setCurrentPrice(0.6 ether);

        nectra.redeem(60 ether, 0);

        uint256 finalBucketDebt = nectraExternal.getBucketDebt(interestRates[2]);
        assertApproxEqRel(finalBucketDebt, 85 ether, 1e11, "Final bucket debt should remain 85 ether");
    }

    function test_redeem_ShouldSkipBucketWithNoDebt() public {
        uint256 LOW_INTEREST_RATE = 0.005 ether;
        uint256 HIGH_INTEREST_RATE = 0.048 ether;
        uint256 SLIGHTLY_HIGHER_INTEREST_RATE = 0.049 ether;

        uint256 tokenIdLow;
        uint256 tokenIdHigh;

        nectra.storeSystemInterestRate(LOW_INTEREST_RATE);
        (tokenIdLow,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, "");
        nectra.storeSystemInterestRate(HIGH_INTEREST_RATE);
        (tokenIdHigh,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 30 ether, "");

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

        // close position at low interest rate
        nectra.modifyPosition(tokenIdLow, type(int256).min, type(int256).min, "");

        // set system interest rate to slightly higher than high interest rate to redeem from high bucket
        nectra.storeSystemInterestRate(SLIGHTLY_HIGHER_INTEREST_RATE);
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

    function test_redeem_ShouldNotBeProfitableWhenRedeemingSelfAtLowestRate() public {
        uint256 LOWEST_INTEREST_RATE = 0.005 ether;
        uint256 collateralAmount = 100 ether;
        uint256 debtAmount = 50 ether;

        uint256 initialETHBalance = address(this).balance;
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        nectra.storeSystemInterestRate(LOWEST_INTEREST_RATE);
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: collateralAmount}(0, int256(collateralAmount), int256(debtAmount), "");

        uint256 postPositionETHBalance = address(this).balance;
        uint256 postPositionNUSDBalance = nectraUSD.balanceOf(address(this));

        (uint256 positionCollateral, uint256 positionDebt,) = nectraExternal.getPosition(tokenId);
        assertEq(positionCollateral, collateralAmount, "Incorrect collateral amount");
        assertEq(positionDebt, debtAmount, "Incorrect debt amount");

        nectraUSD.approve(address(nectra), debtAmount);

        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralWithoutFees = debtAmount.divWad(collateralPrice);

        // Can't redeem 100% of the debt due to redemption slippage check
        // set system interest rate slightly higher than lowest interest rate
        nectra.storeSystemInterestRate(LOWEST_INTEREST_RATE + systemParams.interestRateIncrement);
        uint256 actualCollateralRedeemed = nectra.redeem(debtAmount - 1 wei, 0);

        uint256 ethSpent = initialETHBalance - postPositionETHBalance;
        uint256 ethReceived = address(this).balance - postPositionETHBalance;
        uint256 nusdReceived = postPositionNUSDBalance - initialNUSDBalance;
        uint256 nusdSpent = postPositionNUSDBalance - nectraUSD.balanceOf(address(this));

        assertApproxEqRel(
            actualCollateralRedeemed,
            expectedCollateralWithoutFees - 1 wei,
            1e11,
            "Redemption should result in same collateral as raw conversion due to no fees"
        );

        assertLt(ethReceived, ethSpent, "Should not receive more ETH than initially deposited");
        assertApproxEqRel(nusdReceived, nusdSpent, 1e11, "Should not receive more nUSD than initially deposited");

        (uint256 finalCollateral, uint256 finalDebt,) = nectraExternal.getPosition(tokenId);
        // Due to redeeming 1 wei less and debt rounding 1 wei up, expected remaining debt of 2 wei
        assertEq(finalDebt, 2, "Position should have no remaining debt");
        assertApproxEqRel(
            finalCollateral, collateralAmount - actualCollateralRedeemed, 1e11, "Incorrect remaining collateral"
        );
    }

    function test_redeem_ShouldReaddBucketAfterFullRedemption() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        // set system interest rate slightly above the lowest interest rate
        nectra.storeSystemInterestRate(interestRates[0] + systemParams.interestRateIncrement);
        // fully redeem the bucket
        nectra.redeem(45 ether, 0 ether);

        assertApproxEqRel(nectraExternal.getBucketDebt(interestRates[0]), 0 ether, 1e11);

        // create new debt in the bucket
        nectra.storeSystemInterestRate(interestRates[0]);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 10 ether, "");

        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 10 ether, 1e11);
        assertApproxEqRel(nectraExternal.getBucketDebt(interestRates[0]), 10 ether, 1e11);

        nectra.storeSystemInterestRate(interestRates[0] + systemParams.interestRateIncrement);
        nectra.redeem(10 ether, 0 ether);

        assertApproxEqAbs(nectraExternal.getBucketDebt(interestRates[0]), 0 ether, 1);
        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 0 ether, 1e11);
    }

    function test_redeem_ShouldBeAbleToWithdrawCollateral() public {
        // set system interest rate slightly above the lowest interest rate
        nectra.storeSystemInterestRate(interestRates[0] + systemParams.interestRateIncrement);
        // fully redeem the bucket
        nectra.redeem(45 ether, 0 ether);

        assertApproxEqAbs(nectraExternal.getBucketDebt(interestRates[0]), 0 ether, 1);

        nectra.storeSystemInterestRate(interestRates[0]);
        (, int256 _collateral, int256 _debt,,) =
            nectra.modifyPosition(tokens[1], type(int256).min, type(int256).min, "");

        assertApproxEqRel(_collateral, -70.833333333333333 ether, 1e11); // 100 - 35 / 1.2
        assertApproxEqAbs(_debt, 0 ether, 1);
    }
}
