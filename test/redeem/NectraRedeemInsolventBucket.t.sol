// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemTest, console2} from "test/redeem/NectraRedeem.t.sol";

import {NectraRedeem} from "src/NectraRedeem.sol";
import {NectraBase} from "src/NectraBase.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemInsolventBucketTest is NectraRedeemTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        super.setUp();

        oracle.setCurrentPrice(2.4 ether);

        nectra.modifyPosition{value: 100 ether}(0, int256(100 ether), int256(125 ether), 0.033 ether, "");

        oracle.setCurrentPrice(1.2 ether);
    }
}
