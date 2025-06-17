// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraInterestTest, console2} from "test/NectraInterest.t.sol";

contract NectraInterestExistingTest is NectraInterestTest {
    function setUp() public virtual override {
        super.setUp();

        // Open positions with different interest rates
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 33 ether, 0.1 ether, "");
        nectra.modifyPosition{value: 800 ether}(0, 800 ether, 500 ether, 0.2 ether, "");
        nectra.modifyPosition{value: 600 ether}(0, 600 ether, 200 ether, 0.3 ether, "");

        vm.warp(vm.getBlockTimestamp() + 60 days);
    }

    function test_should_accrue_interest_after_redemption() public override {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 110 ether, 0.1 ether, "");

        // 133 * math.exp(math.log(1 + 0.1) * 60 / 365)
        // = 135.10017699094445
        //
        // To redeem $10 from the new position
        // 10 = x * 110 / (135.10017699094445 + 110)
        // x = 10 / (110 / (135.10017699094445 + 110))
        // x = 22.28183427190404
        nectra.redeem(22.28183427190404 ether, 0);

        _test_interest(tokenId, true);
    }

    function test_update_bucket_accrues_interest() public {
        vm.warp(vm.getBlockTimestamp() + 365 days - 60 days);
        uint256 balanceBefore = nectraUSD.balanceOf(address(cargs.feeRecipientAddress));
        nectra.updateBucket(0.2 ether);
        uint256 balanceAfter = nectraUSD.balanceOf(address(cargs.feeRecipientAddress));
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            500 * 0.2 ether,
            1e11,
            "Fee recipient should receive the interest accrued from the bucket update"
        );
    }
}
