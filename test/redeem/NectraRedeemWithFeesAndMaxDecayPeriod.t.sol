// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest} from "test/redeem/NectraRedeemBase.t.sol";

contract NectraRedeemWithFeesAndMaxDecayPeriodTest is NectraRedeemBaseTest {
    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionDynamicFeeScalar = 1 ether;
        cargs.redemptionFeeDecayPeriod = type(uint256).max; // Fee never decays
        cargs.redemptionFeeTreasuryThreshold = 0 ether; // Full fee sent to treasury
        super.setUp();
    }

    function test_redemption_fee_never_decays_with_max_decay_period() public {
        uint256 redeemTotal = 30 ether;
        // Get initial fee
        uint256 initialFee = nectra.getRedemptionFee(redeemTotal);

        // Redeem to increase volume
        for (uint256 redeemAmount = 1 ether; redeemAmount < redeemTotal; redeemAmount += 1 ether) {
            uint256 redemptionFeeBefore = nectra.getRedemptionFee(1 ether);
            nectra.redeem(1 ether, 0 ether);
            assertGt(
                nectra.getRedemptionFee(1 ether), redemptionFeeBefore, "Fee should increase with redemption volume"
            );

            // Time should have no impact on fee
            vm.warp(block.timestamp + 5 minutes);
        }

        // Fee should have increased after redemptions
        uint256 feeAfterRedemption = nectra.getRedemptionFee(redeemTotal);
        assertGt(feeAfterRedemption, initialFee, "Fee should increase after opening positions");

        // Wait a very long time (1 year)
        vm.warp(block.timestamp + 365 days);

        // Fee should still be the same as after positions were opened
        uint256 finalFee = nectra.getRedemptionFee(redeemTotal);
        assertEq(finalFee, feeAfterRedemption, "Fee should not decay, even after a year");
    }
}
