// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest} from "test/redeem/NectraRedeemBase.t.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemWithFeesPaidToTreasuryTest is NectraRedeemBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionFeeTreasuryThreshold = 0 ether; // 100% fee goes to treasury
        super.setUp();
    }

    function test_redeem_fee_sent_to_treasury() public {
        // Initial balances
        uint256 treasuryBalanceBefore = address(cargs.feeRecipientAddress).balance;

        // Perform a redemption
        uint256 redeemAmount = 100 ether;
        uint256 expectedTreasuryFee = _calculateTreasuryFeeAmount(redeemAmount); // 100 / 1.2 * 0.005 (0.5% fee to treasury at 1.2 ether collateral price)
        uint256 expectedOutput = 82.91666666666667 ether; // 100 / 1.2 * 0.995

        _redeemAndValidate(redeemAmount, expectedOutput, expectedTreasuryFee);

        // Verify treasury received the correct fee portion
        uint256 treasuryBalanceAfter = address(cargs.feeRecipientAddress).balance;

        assertApproxEqRel(
            treasuryBalanceAfter - treasuryBalanceBefore, expectedTreasuryFee, 1e11, "Incorrect treasury fee amount"
        );
    }
}
