// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemGasProfileWithFeesTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionDynamicFeeScalar = 1 ether;
        cargs.redemptionFeeDecayPeriod = 6 hours;
        cargs.redemptionFeeTreasuryThreshold = 0 ether;
        super.setUp();

        for (uint256 i = 0; i < 100; i++) {
            nectra.modifyPosition{value: 10 ether}(
                0, 10 ether, 1 ether, cargs.minimumInterestRate + i * cargs.interestRateIncrement, ""
            );
        }

        for (uint256 i = 0; i < 100; i++) {
            nectra.modifyPosition{value: 10 ether}(
                0, 10 ether, 1 ether, cargs.minimumInterestRate + (i + 256) * cargs.interestRateIncrement, ""
            );
        }

        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, cargs.maximumInterestRate, "");
    }

    function test_gas_profile_redeem() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        uint256 snapshot = vm.snapshotState();
        for (uint256 i = 1; i <= 110; i++) {
            uint256 gasUsed = gasleft();
            nectra.redeem(1 ether * i, 0 ether);
            uint256 gasUsedRedeem = gasUsed - gasleft();
            console2.log(i, gasUsedRedeem);
            vm.revertToState(snapshot);
        }

        uint256 gasUsed = gasleft();
        nectra.redeem(1 ether, 0 ether);
        uint256 gasUsedRedeem = gasUsed - gasleft();
        console2.log("Redeem 1 ether", gasUsedRedeem);
    }
}
