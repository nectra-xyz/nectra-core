// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest} from "test/redeem/NectraRedeemBase.t.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemWithFeesPaidToPositionTest is NectraRedeemBaseTest {
    using FixedPointMathLib for uint256;

    function setUp() public virtual override {
        cargs.redemptionBaseFee = 0.005 ether; // 0.5% base fee
        cargs.redemptionFeeTreasuryThreshold = 1 ether; // 100% fee goes to position
        super.setUp();
    }

    function test_redeem_fee_fully_sent_to_position() public {
        // Initial balances
        uint256 treasuryBalanceBefore = address(cargs.feeRecipientAddress).balance;
        uint256[] memory positionCollateralBefore = new uint256[](tokens.length);
        uint256[] memory positionDebtBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (positionCollateralBefore[i], positionDebtBefore[i]) = nectraExternal.getPosition(tokens[i]);
            positionDebtBefore[i] -= nectraExternal.getPositionOutstandingFee(tokens[i]);
        }

        // Perform a redemption
        uint256 redeemAmount = 100 ether;
        uint256 expectedOutput = 82.91666666666667 ether; // 100 / 1.2 * 0.995
        uint256 expectedFee = 0.4166666666666667 ether; // 100 / 1.2 * 0.005 (0.5% fee)

        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));
        uint256 balanceBefore = address(this).balance;
        nectra.redeem(redeemAmount, 0 ether);

        // Verify treasury balance didn't change
        assertEq(
            address(cargs.feeRecipientAddress).balance, treasuryBalanceBefore, "Treasury balance should not change"
        );

        // Verify nUSD balance decreased by redeem amount
        assertApproxEqRel(
            nectraUSD.balanceOf(address(this)),
            nUSDBalanceBefore - redeemAmount,
            1e11,
            "Incorrect nUSD balance after redeem"
        );

        // Verify received collateral amount
        assertApproxEqRel(address(this).balance, balanceBefore + expectedOutput, 1e11, "Incorrect collateral received");

        // Verify positions were updated correctly with fees kept in position
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        for (uint256 i = 0; i < 5; i++) {
            // the redemption cleared the first 5 buckets
            (uint256 positionCollateral, uint256 positionDebt) = nectraExternal.getPosition(tokens[i]);
            // The position collateral should be reduced by the redemption amount less the fee
            // since the fee stays in the position
            uint256 expectedPositionCollateralWithRedemptionFee =
                uint256(positionDebtBefore[i]).divWad(collateralPrice).mulWad(1 ether - cargs.redemptionBaseFee);
            assertApproxEqRel(
                positionCollateralBefore[i] - positionCollateral,
                expectedPositionCollateralWithRedemptionFee,
                1e11,
                "Incorrect position collateral update"
            );
        }

        //verify last bucket-redeemed-from amount
        (uint256 positionCollateral1, uint256 positionDebt1) = nectraExternal.getPosition(tokens[5]);
        //second last position had debt ratio of 2:3 with last position
        uint256 secondLastPositionProRataDebtDeduction = uint256(5 ether) * 2 / 3;
        uint256 expectedPositionCollateralWithRedemptionFee1 = positionCollateralBefore[5]
            - secondLastPositionProRataDebtDeduction.divWad(collateralPrice).mulWad(1 ether - cargs.redemptionBaseFee);
        assertApproxEqRel(
            positionCollateral1,
            expectedPositionCollateralWithRedemptionFee1,
            1e11,
            "Incorrect second last position collateral update"
        );

        (uint256 positionCollateral2, uint256 positionDebt2) = nectraExternal.getPosition(tokens[6]);
        // last position had debt ratio of 1:3 with second last position
        uint256 lastPositionProRataDebtDeduction = uint256(5 ether) * 1 / 3;
        uint256 expectedPositionCollateralWithRedemptionFee2 = positionCollateralBefore[6]
            - lastPositionProRataDebtDeduction.divWad(collateralPrice).mulWad(1 ether - cargs.redemptionBaseFee);
        assertApproxEqRel(
            positionCollateral2,
            expectedPositionCollateralWithRedemptionFee2,
            1e11,
            "Incorrect last position collateral update"
        );
    }
}
