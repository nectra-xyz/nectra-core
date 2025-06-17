// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest, console2} from "test/redeem/NectraRedeemBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract NectraRedeemWithFeeSplitTest is NectraRedeemBaseTest {
    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionFeeTreasuryThreshold = 0.002 ether; // 0.2% threshold - so 0.3% fee will be sent to treasury
        super.setUp();
    }

    function test_redeem_with_fee_split_iterates_buckets() public {
        {
            _validatePositions();
            _redeemAndValidate(5 ether, 4.145833333333334 ether, 0.0125 ether); // 5 / 1.2 * 0.995; 5 / 1.2 * 0.003
            (collateral[0], debt[0]) = (99.07592592592593 ether, 8.888888889 ether); // (C0 - 5 / 1.2 * 0.998 * D0 / (D0 + D1)); (D0 - 5 * D0 / (D0 + D1))
            (collateral[1], debt[1]) = (96.76574074074074 ether, 31.11111111 ether); // (C1 - 5 / 1.2  * 0.998 * D1 / (D0 + D1)); (D1 - 5 * D1 / (D0 + D1))

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 40 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.051 ether), 5 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.1 ether), 45 ether, "incorrect bucket debt");

            _validatePositions();
        }

        {
            _redeemAndValidate(41 ether, 33.99583333333334 ether, 0.1025 ether); // 41 / 1.2 * 0.995; 41 / 1.2 * 0.003
            (collateral[0], debt[0]) = (91.68333333305611 ether, 0 ether); // (C0 - 40 / 1.2 * 0.998 * D0 / (D0 + D1)); 0
            (collateral[1], debt[1]) = (70.89166666694388 ether, 0 ether); // (C1 - 40 / 1.2  * 0.998 * D1 / (D0 + D1)); 0
            (collateral[2], debt[2]) = (99.16833333333334 ether, 4 ether); // (C2 - 1 / 1.2  * 0.998); (D2 - 1)

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.051 ether), 4 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.1 ether), 45 ether, "incorrect bucket debt");

            _validatePositions();
        }

        {
            _redeemAndValidate(14 ether, 11.608333333333334 ether, 0.035 ether); // 14 / 1.2 * 0.995; 14 / 1.2 * 0.003
            (collateral[2], debt[2]) = (95.84166666666667 ether, 0 ether); // (C2 - 4 / 1.2 * 0.998); (D2 - 4)
            (collateral[3], debt[3]) = (96.3037037037037 ether, 15.55555556 ether); // (C3 - 10 / 1.2  * 0.998 * D3 / (D3 + D4)); (D3 - 10 * D3 / (D3 + D4))
            (collateral[4], debt[4]) = (95.37962962962963 ether, 19.44444444 ether); // (C4 - 10 / 1.2  * 0.998 * D4 / (D3 + D4)); (D3 - 10 * D4 / (D3 + D4))

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.051 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.1 ether), 35 ether, "incorrect bucket debt");

            _validatePositions();
        }
    }

    function test_redeem_fee_fully_to_treasury() public {
        // Perform a redemption
        uint256 redeemAmount = 10 ether;
        uint256 expectedFee = 0.025 ether; // 10 / 1.2 * 0.003 (0.3% fee)
        uint256 expectedOutput = 8.291666666666667 ether; // 10 / 1.2 * 0.995

        _redeemAndValidate(redeemAmount, expectedOutput, expectedFee);

        // Verify positions were updated correctly
        (collateral[0], debt[0]) = (98.15185185185185 ether, 7.777777778 ether);
        (collateral[1], debt[1]) = (93.53148148148148 ether, 27.22222222 ether);
        _validatePositions();
    }

    function test_redeem_fee_split_between_treasury_and_positions() public {
        // Initial balances
        uint256 treasuryBalanceBefore = address(cargs.feeRecipientAddress).balance;
        uint256[] memory positionBalancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            positionBalancesBefore[i] = address(this).balance;
        }

        // Perform a redemption
        uint256 redeemAmount = 100 ether;
        uint256 expectedTreasuryFee = _calculateTreasuryFeeAmount(redeemAmount); // 100 / 1.2 * 0.003 (0.3% fee to treasury at 1.2 ether collateral price)
        uint256 expectedOutput = 82.91666666666667 ether; // 100 / 1.2 * 0.995

        _redeemAndValidate(redeemAmount, expectedOutput, expectedTreasuryFee);

        // Verify treasury received the correct fee portion
        uint256 treasuryBalanceAfter = address(cargs.feeRecipientAddress).balance;

        assertApproxEqRel(
            treasuryBalanceAfter - treasuryBalanceBefore, expectedTreasuryFee, 1e11, "Incorrect treasury fee amount"
        );
    }
}
