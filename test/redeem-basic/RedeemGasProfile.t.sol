// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console} from "test/NectraBase.t.sol";

contract RedeemGasProfileTest is NectraBaseTest {
    function setUp() public virtual override {
        super.setUp();

        // nectra.createRedemptionBufferPosition{value: 10 ether}(10 ether, 1 ether, address(this));

        for (uint256 i = 0; i < 60; i++) {
            nectra.storeSystemInterestRate(systemParams.minimumInterestRate + i * systemParams.interestRateIncrement);
            nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, "");
        }

        for (uint256 i = 0; i < 60; i++) {
            nectra.storeSystemInterestRate(
                systemParams.minimumInterestRate + (i + 256) * systemParams.interestRateIncrement
            );
            nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, "");
        }

        nectra.storeSystemInterestRate(systemParams.maximumInterestRate);
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, "");

        nectra.storeSystemInterestRate(systemParams.minimumInterestRate + 255 * systemParams.interestRateIncrement);
    }

    function test_gas_profile_redeem() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        uint256 snapshot = vm.snapshotState();
        for (uint256 i = 1; i <= 80; i++) {
            uint256 gasUsed = gasleft();
            nectra.redeem(1 ether * i, 0 ether);
            uint256 gasUsedRedeem = gasUsed - gasleft();
            console.log(i, gasUsedRedeem);
            vm.revertToState(snapshot);
        }

        uint256 gasUsed = gasleft();
        nectra.redeem(1 ether, 0 ether);
        uint256 gasUsedRedeem = gasUsed - gasleft();
        console.log("Redeem 1 ether", gasUsedRedeem);
    }
}
