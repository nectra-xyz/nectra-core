// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraOpenFeeTest, console2} from "test/NectraOpenFee.t.sol";

contract NectraOpenFeeExistingTest is NectraOpenFeeTest {
    function setUp() public virtual override {
        super.setUp();

        // Open positions with different interest rates
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        nectra.modifyPosition{value: 800 ether}(0, 800 ether, 500 ether, 0.2 ether, "");
        nectra.modifyPosition{value: 600 ether}(0, 600 ether, 200 ether, 0.3 ether, "");

        vm.warp(vm.getBlockTimestamp() + 365 days);
    }
}
