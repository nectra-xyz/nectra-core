// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraBase} from "src/NectraBase.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemInsolventBucketTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    uint256 internal constant INSOLVENT_BUCKET = 0.033 ether;

    function setUp() public virtual override {
        super.setUp();

        // fill lowest bucket with position that will remain solvent
        nectra.modifyPosition{value: 100 ether}(0, int256(100 ether), int256(25 ether), systemParams.minimumInterestRate, "");
        // fill upper bucket with position that will remain solvent
        nectra.modifyPosition{value: 100 ether}(0, int256(100 ether), int256(30 ether), 0.05 ether, "");

        nectraUSD.approve(address(nectra), type(uint256).max);
    }

    function test_redemption_should_skip_if_bucket_is_insolvant() public {
        (uint256 currentPrice,) = oracle.getLatestPrice();
        uint256 collateralAmount = 10 ether;
        uint256 collateralValue = collateralAmount.mulWad(currentPrice);
        uint256 maxDebt = collateralValue.divWad(systemParams.issuanceRatio);
        uint256 targetPrice = systemParams.fullLiquidationRatio.mulWad(1 ether + systemParams.openFeePercentage).mulWad(maxDebt).divWad(collateralAmount);

        // fill insolvent bucket with position that will be insolvent
        nectra.modifyPosition{ value: collateralAmount }(0, int256(collateralAmount), int256(maxDebt), INSOLVENT_BUCKET, "");

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
