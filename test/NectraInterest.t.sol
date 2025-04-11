// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract NectraInterestTest is NectraBaseTest {
    function setUp() public virtual override {
        cargs.openFeePercentage = 0;
        super.setUp();

        nectraUSD.approve(address(nectra), type(uint256).max);
    }

    function test_interest_view_only() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        _test_interest(tokenId, false);
    }

    function test_interest_compounded() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        _test_interest(tokenId, true);
    }

    /// Test the same but with another position in the same bucket
    function test_interest_existing_compounded() public {
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");

        _test_interest(tokenId, true);
    }

    /// Joining the same bucket with a position that already has interest accrued
    function test_interest_existing_already_accrued() public {
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");

        vm.warp(vm.getBlockTimestamp() + 60 days);

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        _test_interest(tokenId, true);
    }

    function test_interest_after_modification() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        vm.warp(vm.getBlockTimestamp() + 7 days);

        // debt after 7 days = 100.1829538 ether
        assertApproxEqAbs(nectraExternal.getPositionDebt(tokenId), 100.1829538 ether, 1e11); // 7 decimals

        nectraUSD.approve(address(nectra), nectraExternal.getPositionDebt(tokenId) - 100 ether);
        nectra.modifyPosition(
            tokenId, 0 ether, -int256(nectraExternal.getPositionDebt(tokenId) - 100 ether), 0.1 ether, ""
        );

        _test_interest(tokenId, true);
    }

    function test_should_accrue_interest_after_redemption() public virtual {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 110 ether, 0.1 ether, "");

        nectra.redeem(10 ether, 0);

        _test_interest(tokenId, true);
    }

    /**
     * |--------------------------|
     * | interest rate is 10% p/a |
     * | principal is $1000       |
     * |--------------------------|
     * | time       | debt        |
     * |--------------------------|
     * | 0          | 1000        |
     * | 86400      | 100.0261158 |
     * | 604800     | 100.1829538 |
     * | 2678400    | 100.8127689 |
     * | 15811200   | 104.8945792 |
     * | 31536000   | 110         |
     * | 63072000   | 121         |
     * |--------------------------|
     */
    function _test_interest(uint256 tokenId, bool compound) internal {
        uint256 startTime = vm.getBlockTimestamp();

        uint256[7] memory timestamps;
        uint256[7] memory expected;

        (timestamps[0], expected[0]) = (uint256(0), uint256(100 ether));
        (timestamps[1], expected[1]) = (uint256(86400), uint256(100.0261158 ether));
        (timestamps[2], expected[2]) = (uint256(604800), uint256(100.1829538 ether));
        (timestamps[3], expected[3]) = (uint256(2678400), uint256(100.8127689 ether));
        (timestamps[4], expected[4]) = (uint256(15811200), uint256(104.8945792 ether));
        (timestamps[5], expected[5]) = (uint256(31536000), uint256(110 ether));
        (timestamps[6], expected[6]) = (uint256(63072000), uint256(121 ether));

        for (uint256 i = 0; i < expected.length; i++) {
            vm.warp(startTime + timestamps[i]);
            if (compound) nectra.updatePosition(tokenId);
            assertApproxEqAbs(nectraExternal.getPositionDebt(tokenId), expected[i], 1e11); // 7 decimals
        }
    }
}
