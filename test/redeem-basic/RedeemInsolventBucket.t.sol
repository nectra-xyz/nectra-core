// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console} from "test/NectraBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraBase} from "src/NectraBase.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract RedeemInsolventBucketTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    uint256 internal constant INSOLVENT_BUCKET = 0.033 ether;

    function setUp() public virtual override {
        super.setUp();

        // fill lowest bucket with position that will remain solvent
        nectra.storeSystemInterestRate(systemParams.minimumInterestRate);
        nectra.modifyPosition{value: 100 ether}(0, int256(100 ether), int256(25 ether), "");
        // fill upper bucket with position that will remain solvent
        nectra.storeSystemInterestRate(0.05 ether);
        nectra.modifyPosition{value: 100 ether}(0, int256(100 ether), int256(30 ether), "");

        nectraUSD.approve(address(nectra), type(uint256).max);
    }

    function test_redeem_ShouldSkipIfBucketIsInsolvant() public {
        (uint256 currentPrice,) = oracle.getLatestPrice();
        uint256 collateralAmount = 10 ether;
        uint256 collateralValue = collateralAmount.mulWad(currentPrice);
        uint256 maxDebt = collateralValue.divWad(systemParams.issuanceRatio);
        uint256 targetPrice = systemParams.fullLiquidationRatio.mulWad(1 ether + systemParams.openFeePercentage).mulWad(
            maxDebt
        ).divWad(collateralAmount);

        // fill insolvent bucket with position that will be insolvent
        nectra.storeSystemInterestRate(INSOLVENT_BUCKET);
        nectra.modifyPosition{value: collateralAmount}(0, int256(collateralAmount), int256(maxDebt), "");

        // make bucket insolvent by dropping price
        oracle.setCurrentPrice(targetPrice);

        uint256 redeemAmount = 50 ether;

        // perform redemption, it should skip the insolvent bucket
        uint256 lowestBucketDebtBefore = nectraExternal.getBucketDebt(systemParams.minimumInterestRate);
        uint256 insolventBucketDebtBefore = nectraExternal.getBucketDebt(INSOLVENT_BUCKET);
        uint256 nextBucketDebtBefore = nectraExternal.getBucketDebt(0.05 ether);

        nectra.redeem(redeemAmount, 0);

        uint256 lowestBucketDebtAfter = nectraExternal.getBucketDebt(systemParams.minimumInterestRate);
        uint256 insolventBucketDebtAfter = nectraExternal.getBucketDebt(INSOLVENT_BUCKET);
        uint256 nextBucketDebtAfter = nectraExternal.getBucketDebt(0.05 ether);

        assertEq(lowestBucketDebtAfter, 0, "Lowest bucket not fully redeemed");
        assertEq(insolventBucketDebtAfter, insolventBucketDebtBefore, "Insolvent bucket redeemed");
        // the next bucket should be less the remaining amount
        uint256 expectedNextBucketDebt = nextBucketDebtBefore - (redeemAmount - lowestBucketDebtBefore);
        assertEq(nextBucketDebtAfter, expectedNextBucketDebt, "Next bucket not redeemed");
    }
}
