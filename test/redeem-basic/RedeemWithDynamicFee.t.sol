// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RedeemBaseTest, console} from "test/redeem-basic/RedeemBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract RedeemWithDynamicFeeTest is RedeemBaseTest {
    function setUp() public virtual override {
        systemParams.redemptionDynamicFeeScalar = 1 ether;
        super.setUp();
    }

    function test_redeem_WithDynamicFeeAdditive() public {
        nectraUSD.approve(address(nectra), type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        uint256 redeemedFull = nectra.redeem(65 ether, 0 ether);

        vm.revertToState(snapshot);

        uint256 redeemedPartial1 = nectra.redeem(40 ether, 0 ether);
        uint256 redeemedPartial2 = nectra.redeem(5 ether, 0 ether);
        uint256 redeemedPartial3 = nectra.redeem(20 ether, 0 ether);

        assertApproxEqRel(redeemedFull, redeemedPartial1 + redeemedPartial2 + redeemedPartial3, 1e11);
    }

    function test_redeem_RedemptionFeeShouldDecay() public {
        uint256 startTime = vm.getBlockTimestamp();
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(10 ether, 0);

        uint256[5] memory redemptionFee;
        uint256[5] memory timestamps;

        // fee(10, 10, 0, 1, 130) = 0.12059790742950902
        (timestamps[0], redemptionFee[0]) = (0, 0.12059790742950902 ether);

        // 30 min
        // fee(10, 9.166666666666666, 0, 1, 130) = 0.1139276817900475
        (timestamps[1], redemptionFee[1]) = (1800, 0.1139276817900475 ether);

        // 3 hours
        // fee(10, 5, 0, 1, 130) = 0.08057655359274082
        (timestamps[2], redemptionFee[2]) = (10800, 0.08057655359274082 ether);

        // 5 hours
        // fee(10, 1.666666666666666, 0, 1, 130) = 0.05389565103489531
        (timestamps[3], redemptionFee[3]) = (18000, 0.05389565103489531 ether);

        // 6 hours
        // fee(10, 0, 0, 1, 130) = 0.04055519975597264
        (timestamps[4], redemptionFee[4]) = (21600, 0.04055519975597264 ether);

        for (uint256 i = 0; i < timestamps.length; i++) {
            vm.warp(startTime + timestamps[i]);
            assertApproxEqAbs(nectra.getRedemptionFee(10 ether), redemptionFee[i], 1e11, "incorrect redemptionFee");
        }
    }
}
