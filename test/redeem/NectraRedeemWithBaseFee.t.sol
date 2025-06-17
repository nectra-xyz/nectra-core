// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest, console2} from "test/redeem/NectraRedeemBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemWithBaseFeeTest is NectraRedeemBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        super.setUp();
    }

    function test_redeem_with_base_fee_iterates_buckets() public {
        {
            _validatePositions();
            _redeemAndValidate(5 ether, 4.145833333333334 ether, 0); // 5 / 1.2 * 0.995
            (collateral[0], debt[0]) = (99.07870370370371 ether, 8.888888889 ether); // (C0 - 5 / 1.2 * 0.995 * D0 / (D0 + D1)); (D0 - 5 * D0 / (D0 + D1))
            (collateral[1], debt[1]) = (96.77546296296296 ether, 31.11111111 ether); // (C1 - 5 / 1.2  * 0.995 * D1 / (D0 + D1)); (D1 - 5 * D1 / (D0 + D1))
            _validatePositions();
        }

        {
            _redeemAndValidate(41 ether, 33.99583333333334 ether, 0); // 41 / 1.2 * 0.995
            (collateral[0], debt[0]) = (91.70833333305694 ether, 0 ether); // (C0 - 40 / 1.2 * 0.995 * D0 / (D0 + D1)); 0
            (collateral[1], debt[1]) = (70.97916666694304 ether, 0 ether); // (C1 - 40 / 1.2  * 0.995 * D1 / (D0 + D1)); 0
            (collateral[2], debt[2]) = (99.17083333333333 ether, 4 ether); // (C2 - 1 / 1.2  * 0.995); (D2 - 1)
            _validatePositions();
        }

        {
            _redeemAndValidate(14 ether, 11.608333333333334 ether, 0); // 14 / 1.2 * 0.995
            (collateral[2], debt[2]) = (95.85416666666667 ether, 0 ether); // (C2 - 4 / 1.2 * 0.995); (D2 - 4)
            (collateral[3], debt[3]) = (96.31481481481481 ether, 15.55555556 ether); // (C3 - 10 / 1.2  * 0.995 * D3 / (D3 + D4)); (D3 - 10 * D3 / (D3 + D4))
            (collateral[4], debt[4]) = (95.39351851851852 ether, 19.44444444 ether); // (C4 - 10 / 1.2  * 0.995 * D4 / (D3 + D4)); (D3 - 10 * D4 / (D3 + D4))
            _validatePositions();
        }
    }

    function test_redeem_with_base_fee_readd_bucket() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(60 ether, 0 ether);
        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1e11);

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 10 ether, 0.05 ether, "");
        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 10 ether, 1e11);

        nectra.redeem(10 ether, 0 ether);
        assertApproxEqAbs(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1);
        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 0 ether, 1e11);
    }

    function test_redeem_with_base_fee_withdraw_collateral() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(65 ether, 0 ether);
        assertApproxEqAbs(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1, "Bucket debt not redeemed to zero");

        uint256 balanceBefore = address(this).balance;
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));

        (, int256 collateral, int256 debt,,) =
            nectra.modifyPosition(tokens[1], type(int256).min, type(int256).min, 0.05 ether, "");

        uint256 expectedCollateral = balanceBefore + (100 ether - 29.020833333333332 ether);
        assertApproxEqRel(address(this).balance, expectedCollateral, 1e11, "Incorrect collateral after redeem");
        assertEq(nUSDBalanceBefore, nectraUSD.balanceOf(address(this)), "No nUSD should be burned to close");
    }

    function test_getRedemptionFee_accuracy_to_calculate_minAmountOut() public {
        address redeemer = makeAddr("redeemer");

        nectraUSD.transfer(redeemer, 50 ether);

        uint256 redeemAmount = 50 ether;
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralBeforeFees = redeemAmount.divWad(collateralPrice);

        uint256 redemptionFee = nectra.getRedemptionFee(redeemAmount);

        uint256 expectedCollateralAfterFees = expectedCollateralBeforeFees.mulWad(1 ether - redemptionFee);

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
        assertEq(nectraUSD.balanceOf(redeemer), 0, "Redeemer should have no nUSD left");

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

    function test_amount_of_nUSD_burned_should_equal_BucketDebtDecrease_and_CollateralDecrease_while_receiving_CollateralLessTheFee(
    ) public {
        uint256 redeemAmount = 10 ether;
        nectraUSD.approve(address(nectra), type(uint256).max);

        uint256 initialNUSDSupply = nectraUSD.totalSupply();
        uint256 initialUserNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialUserETHBalance = address(this).balance;
        uint256 initialFeeRecipientBalance = address(cargs.feeRecipientAddress).balance;
        uint256 initialBucketDebt = nectraExternal.getBucketDebt(0.05 ether);

        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralBeforeFees = redeemAmount.divWad(collateralPrice);

        uint256 actualCollateralRedeemed = nectra.redeem(redeemAmount, 0);

        uint256 finalNUSDSupply = nectraUSD.totalSupply();
        uint256 finalUserNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 finalUserETHBalance = address(this).balance;
        uint256 finalFeeRecipientBalance = address(cargs.feeRecipientAddress).balance;
        uint256 finalBucketDebt = nectraExternal.getBucketDebt(0.05 ether);

        uint256 nUSDBurned = initialNUSDSupply - finalNUSDSupply;
        uint256 userNUSDDecrease = initialUserNUSDBalance - finalUserNUSDBalance;
        uint256 bucketDebtDecrease = initialBucketDebt - finalBucketDebt;
        uint256 userCollateralReceived = finalUserETHBalance - initialUserETHBalance;
        uint256 feeRecipientReceived = finalFeeRecipientBalance - initialFeeRecipientBalance;
        uint256 totalCollateralRedeemed = userCollateralReceived + feeRecipientReceived;
        uint256 feeRecipientExpectedAmount = expectedCollateralBeforeFees - actualCollateralRedeemed;

        //assertEq(feeRecipientExpectedAmount, feeRecipientReceived, "Fee recipient expected received amount should match actual fee recipient amount received");
        assertEq(nUSDBurned, redeemAmount, "Incorrect amount of nUSD burned");
        assertEq(userNUSDDecrease, redeemAmount, "User nUSD balance decrease should match redeem amount");
        assertEq(bucketDebtDecrease, redeemAmount, "Bucket debt decrease should match redeem amount");
        assertApproxEqRel(
            totalCollateralRedeemed,
            expectedCollateralBeforeFees,
            1e16,
            "Total collateral redeemed should match expected amount"
        );
    }
}
