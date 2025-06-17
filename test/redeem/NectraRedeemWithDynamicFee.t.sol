// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest, console2} from "test/redeem/NectraRedeemBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract NectraRedeemWithDynamicFeeTest is NectraRedeemBaseTest {
    function setUp() public virtual override {
        cargs.redemptionDynamicFeeScalar = 1 ether;
        super.setUp();
    }

    function test_redeem_with_dynamic_fee_iterates_buckets() public {
        /**
         * import math
         * def fee(x, H, R, k, T):
         *   return (R * x + k * ((H + T) * math.log(T / (T - x)) - x))/x
         */
        _validatePositions();

        {
            // fee(5, 0, 0, 1, 140) = 0.01829403678449424
            _redeemAndValidate(5 ether, 4.090441513397941 ether, 0); // W = 5 / 1.2 * (1 - 0.01829403678449424)
            (collateral[0], debt[0]) = (99.09101299702267 ether, 8.888888889 ether); // (C0 - W * D0 / (D0 + D1)); (D0 - 5 * D0 / (D0 + D1))
            (collateral[1], debt[1]) = (96.81854548957938 ether, 31.11111111 ether); // (C1 - W * D1 / (D0 + D1)); (D1 - 5 * D1 / (D0 + D1))
            _validatePositions();
        }

        {
            // fee(41, 5, 0, 1, 140 - 5) = 0.23602925520925813
            _redeemAndValidate(41 ether, 26.102333780350353 ether, 0); // W0 = 40 / 1.2 * (1 - 0.23602925520925813), W1 = 1 / 1.2 * (1 - 0.23602925520925813)
            (collateral[0], debt[0]) = (93.43197044280497 ether, 0 ether); // (C0 - W0 * D0 / (D0 + D1)); 0
            (collateral[1], debt[1]) = (77.01189655077235 ether, 0 ether); // (C1 - W0 * D1 / (D0 + D1)); 0
            (collateral[2], debt[2]) = (99.36335771267439 ether, 4 ether); // (C2 - W1); (D2 - 1)
            _validatePositions();
        }

        {
            vm.warp(vm.getBlockTimestamp() + 3 hours);

            debt[2] = 4.000068140432294 ether; // D2 = D2 * math.exp(math.log(1+I2)* 3 hours / 365 days)
            debt[3] = 20.000652820104836 ether; // D3 = D3 * math.exp(math.log(1+I3)* 3 hours / 365 days)
            debt[4] = 25.000816025131044 ether; // D4 = D4 * math.exp(math.log(1+I4)* 3 hours / 365 days)
            debt[5] = 30.001873225159827 ether; // D5 = D5 * math.exp(math.log(1+I5)* 3 hours / 365 days)
            debt[6] = 15.000936612579913 ether; // D6 = D6 * math.exp(math.log(1+I6)* 3 hours / 365 days)
            _validatePositions();

            // fee(14, (5 + 41) / 2, 0, 1, 94.00434682340793) = 0.34772339028338706
            _redeemAndValidate(14 ether, 7.609893780027152 ether, 0); // W0 = D2 / 1.2 * (1 - 0.34772339028338706), W1 = (14 - D2) / 1.2 * (1 - 0.34772339028338706)
            (collateral[2], debt[2]) = (97.18906530827721 ether, 0 ether); // (C2 - W0); (D2 - 4)
            (collateral[3], debt[3]) = (97.58417716638668 ether, 15.556238660296966 ether); // (C3 - W1 * D3 / (D3 + D4)); (D3 - (14 - D2) * D3 / (D3 + D4))
            (collateral[4], debt[4]) = (96.98022145798335 ether, 19.44529832537121 ether); // (C4 - W1 * D4 / (D3 + D4)); (D4 - (14 - D2) * D4 / (D3 + D4))

            _validatePositions();
        }

        {
            vm.warp(vm.getBlockTimestamp() + 12 hours);

            debt[3] = 15.558269844814726 ether; // D3 = D3 * math.exp(math.log(1+I3)* 12 hours / 365 days)
            debt[4] = 19.44783730601841 ether; // D4 = D4 * math.exp(math.log(1+I4)* 12 hours / 365 days)
            debt[5] = 30.009367295529685 ether; // D5 = D5 * math.exp(math.log(1+I5)* 12 hours / 365 days)
            debt[6] = 15.004683647764843 ether; // D6 = D6 * math.exp(math.log(1+I6)* 12 hours / 365 days)
            _validatePositions();

            // fee(1, 0, 0, 1, 80.020158094127671245) = 0.006300975482925963
            _redeemAndValidate(1 ether, 0.828082520430895 ether, 0); // W = 1 / 1.2 * (1 - 0.006300975482925963)
            (collateral[3], debt[3]) = (97.21614049063962 ether, 15.113825400370281 ether); // (C3 - W * D3 / (D3 + D4)); (D3 - 1 * D3 / (D3 + D4))
            (collateral[4], debt[4]) = (96.52017561329951 ether, 18.892281750462853 ether); // (C4 - W * D4 / (D3 + D4)); (D4 - 1 * D4 / (D3 + D4))

            _validatePositions();
        }
    }

    function test_redeem_with_dynamic_fee_additive() public {
        nectraUSD.approve(address(nectra), type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        uint256 redeemedFull = nectra.redeem(65 ether, 0 ether);

        vm.revertToState(snapshot);

        uint256 redeemedPartial1 = nectra.redeem(40 ether, 0 ether);
        uint256 redeemedPartial2 = nectra.redeem(5 ether, 0 ether);
        uint256 redeemedPartial3 = nectra.redeem(20 ether, 0 ether);

        assertApproxEqRel(redeemedFull, redeemedPartial1 + redeemedPartial2 + redeemedPartial3, 1e11);
    }

    function test_redemption_fee_should_decay() public {
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
