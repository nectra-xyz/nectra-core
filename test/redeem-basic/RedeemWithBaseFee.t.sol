// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RedeemBaseTest, console} from "test/redeem-basic/RedeemBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract RedeemWithBaseFeeTest is RedeemBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        systemParams.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        super.setUp();
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

    function test_redeem_ShouldBeAbleToCalculateMinAmountOutUsinggetRedemptionFee() public {
        address redeemer = makeAddr("redeemer");
        uint256 redeemAmount = 50 ether;

        nectraUSD.transfer(redeemer, redeemAmount * 2);

        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralBeforeFees = redeemAmount.divWad(collateralPrice);

        uint256 redemptionFee = nectra.getRedemptionFee(redeemAmount);
        uint256 expectedCollateralAfterFees = expectedCollateralBeforeFees.mulWad(UNIT - redemptionFee);
        uint256 minAmountOut = expectedCollateralAfterFees.mulWad(0.999 ether);
        uint256 redeemerInitialETH = redeemer.balance;

        vm.startPrank(redeemer);
        nectraUSD.approve(address(nectra), type(uint256).max);
        uint256 actualCollateralRedeemed = nectra.redeem(redeemAmount, minAmountOut);
        vm.stopPrank();

        uint256 redeemerFinalETH = redeemer.balance;
        uint256 actualCollateralReceived = redeemerFinalETH - redeemerInitialETH;

        assertApproxEqRel(
            actualCollateralRedeemed, expectedCollateralAfterFees, 1e11, "Incorrect collateral redeemed amount"
        );
        assertApproxEqRel(actualCollateralReceived, expectedCollateralAfterFees, 1e11, "Incorrect collateral received");

        uint256 tooHighMinAmountOut = expectedCollateralAfterFees.mulWad(1.001 ether);

        vm.startPrank(redeemer);
        nectraUSD.approve(address(nectra), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraRedeem.MinAmountOutNotMet.selector, actualCollateralRedeemed, tooHighMinAmountOut
            )
        );
        nectra.redeem(redeemAmount, tooHighMinAmountOut);
        vm.stopPrank();
    }

    function test_redeem_BucketDebtUpdatedCorrectly() public {
        uint256 redeemAmount = 10 ether;
        nectraUSD.approve(address(nectra), type(uint256).max);

        uint256 initialUserNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialUserETHBalance = address(this).balance;
        uint256 initialBucketDebt = nectraExternal.getBucketDebt(interestRates[0]);

        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralBeforeFees = redeemAmount.divWad(collateralPrice);

        // set system interest rate slightly above the lowest interest rate
        nectra.storeSystemInterestRate(interestRates[0] + systemParams.interestRateIncrement);
        uint256 actualCollateralRedeemed = nectra.redeem(redeemAmount, 0);

        uint256 userCollateralReceived = address(this).balance - initialUserETHBalance;

        assertEq(
            nectraUSD.balanceOf(address(this)),
            initialUserNUSDBalance - redeemAmount,
            "User nUSD balance decrease should match redeem amount"
        );
        assertEq(
            nectraExternal.getBucketDebt(interestRates[0]),
            initialBucketDebt - redeemAmount,
            "Bucket debt decrease should match redeem amount"
        );
        assertEq(
            actualCollateralRedeemed, userCollateralReceived, "Total collateral redeemed should match expected amount"
        );
        assertApproxEqRel(
            userCollateralReceived,
            expectedCollateralBeforeFees,
            1e16,
            "Total collateral redeemed should match expected amount"
        );
    }
}
