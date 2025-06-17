// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest} from "test/redeem/NectraRedeemBase.t.sol";

contract NectraRedeemWithFeesAndZeroDecayPeriodTest is NectraRedeemBaseTest {
    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionDynamicFeeScalar = 1 ether;
        cargs.redemptionFeeDecayPeriod = 0 hours; // Fee decays to base fee instantly
        cargs.redemptionFeeTreasuryThreshold = 0 ether; // Full fee sent to treasury
        super.setUp();
    }

    function test_redemption_fee_decay_to_base_fee() public {
        uint256 redeemTotal = 30 ether;
        // Get initial fee
        uint256 initialFee = nectra.getRedemptionFee(redeemTotal);

        // Redeem to increase volume
        for (uint256 redeemAmount = 1 ether; redeemAmount < redeemTotal; redeemAmount += 1 ether) {
            uint256 redemptionFeeBefore = nectra.getRedemptionFee(1 ether);
            nectra.redeem(1 ether, 0 ether);
            // Note: Open a new position to restore total debt, this test case is strictly measuring the decay of the fee
            // even as redemption volume increase. If the total debt is not restored, the fee will increase due to the ratio
            // between total debt and the redemption amount increasing and seem as if the fee is not decaying.
            nectra.modifyPosition{value: 2 ether}(0, 2 ether, 1 ether, 0.5 ether, "");
            assertEq(
                nectra.getRedemptionFee(1 ether),
                redemptionFeeBefore,
                "Fee should decay instantly even as volume increases"
            );

            // TODO: why does time impact this test?
            // vm.warp(block.timestamp + 1 hours);
        }

        // Fee should have increased after redemptions
        uint256 feeAfterRedemption = nectra.getRedemptionFee(redeemTotal);
        assertEq(feeAfterRedemption, initialFee, "Fee should have decayed after redemptions");

        // Wait 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Fee should decay to base fee
        uint256 finalFee = nectra.getRedemptionFee(redeemTotal);
        assertEq(finalFee, feeAfterRedemption, "Fee unchanged after 1 hour");
    }
}
