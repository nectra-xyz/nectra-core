// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

contract NectraOpenFeeTest is NectraBaseTest {
    function setUp() public virtual override {
        systemParams.openFeePercentage = 0.005 ether; // 0.5%
        super.setUp();

        nectraUSD.approve(address(nectra), type(uint256).max);
    }

    function test_open_fee_is_charged() public {
        nectra.storeSystemInterestRate(0.1 ether);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, "");

        uint256 expectedDebt = 100 ether + 100 ether * systemParams.openFeePercentage / UNIT;
        _checkPosition(tokenId, 1000 ether, expectedDebt, 0.1 ether);


        // increase debt
        nectra.modifyPosition(tokenId, 0 ether, 100 ether, "");

        expectedDebt = expectedDebt + 100 ether + 100 ether * systemParams.openFeePercentage / UNIT;
        _checkPosition(tokenId, 1000 ether, expectedDebt, 0.1 ether);

        // decrease debt
        nectra.modifyPosition(tokenId, 0 ether, -100 ether, "");

        expectedDebt = expectedDebt - 100 ether;
        _checkPosition(tokenId, 1000 ether, expectedDebt, 0.1 ether);
    }
}
