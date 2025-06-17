// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NectraLib} from "src/NectraLib.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraRedeemBaseTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    uint256[] internal tokens;
    uint256[] internal interestRates;
    uint256[] internal debt;
    uint256[] internal collateral;

    function setUp() public virtual override {
        super.setUp();

        // set array lengths
        assembly {
            sstore(tokens.slot, 7)
            sstore(interestRates.slot, 7)
            sstore(debt.slot, 7)
            sstore(collateral.slot, 7)
        }

        (collateral[0], debt[0], interestRates[0]) = (100 ether, 10 ether, 0.05 ether);
        (collateral[1], debt[1], interestRates[1]) = (100 ether, 35 ether, 0.05 ether);
        (collateral[2], debt[2], interestRates[2]) = (100 ether, 5 ether, 0.05 ether + cargs.interestRateIncrement);
        (collateral[3], debt[3], interestRates[3]) = (100 ether, 20 ether, 0.1 ether);
        (collateral[4], debt[4], interestRates[4]) = (100 ether, 25 ether, 0.1 ether);
        (collateral[5], debt[5], interestRates[5]) = (100 ether, 30 ether, 0.2 ether);
        (collateral[6], debt[6], interestRates[6]) = (100 ether, 15 ether, 0.2 ether);

        for (uint256 i = 0; i < interestRates.length; i++) {
            (tokens[i],,,,) = nectra.modifyPosition{value: collateral[i]}(
                0, int256(collateral[i]), int256(debt[i]), interestRates[i], ""
            );
        }

        nectraUSD.approve(address(nectra), type(uint256).max);
    }

    function _redeemAndValidate(uint256 amount, uint256 amountOut, uint256 fee) internal {
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));
        uint256 balanceBefore = address(this).balance;
        uint256 treasuryBalanceBefore = address(cargs.feeRecipientAddress).balance;
        uint256 globalDebtBefore;
        for (uint256 i = 0; i < tokens.length; i++) {
            globalDebtBefore += debt[i];
        }
        nectra.redeem(amount, 0 ether);

        for (uint256 i = 0; i < tokens.length; i++) {
            nectra.updatePosition(tokens[i]);
        }
        uint256 nUSDBalanceAfter = nectraUSD.balanceOf(address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 treasuryBalanceAfter = address(cargs.feeRecipientAddress).balance;
        NectraLib.GlobalState memory globalStateAfter = nectra.getGlobalState();
        assertApproxEqRel(nUSDBalanceBefore - nUSDBalanceAfter, amount, 1e11, "Incorrect balance after redeem");
        assertApproxEqRel(balanceAfter - balanceBefore, amountOut, 1e11, "Incorrect balance after redeem");
        assertApproxEqRel(
            treasuryBalanceAfter - treasuryBalanceBefore, fee, 1e11, "Incorrect treasury balance after redeem"
        );
        assertApproxEqRel(globalDebtBefore - globalStateAfter.debt, amount, 1e11, "Incorrect total debt after redeem");
    }

    function _validatePositions() internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            nectra.updatePosition(tokens[i]);
            (uint256 positionCollateral, uint256 positionDebt) = nectraExternal.getPosition(tokens[i]);
            assertApproxEqRel(positionCollateral, collateral[i], 1e11);
            assertApproxEqRel(positionDebt, debt[i], 1e11);
        }
    }

    function _calculateTreasuryFeeAmount(uint256 redeemAmount) internal view returns (uint256 treasuryFeeAmount) {
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 expectedCollateralBeforeFees = redeemAmount * UNIT / collateralPrice;

        uint256 redemptionFeePercentage = nectra.getRedemptionFee(redeemAmount);
        uint256 treasuryFeePercentage = redemptionFeePercentage > cargs.redemptionFeeTreasuryThreshold
            ? redemptionFeePercentage - cargs.redemptionFeeTreasuryThreshold
            : 0;

        uint256 expectedCollateralAfterRedemptionFees = expectedCollateralBeforeFees
            - expectedCollateralBeforeFees.mulWad(redemptionFeePercentage - treasuryFeePercentage);
        treasuryFeeAmount = expectedCollateralAfterRedemptionFees.divWad(
            1 ether - (redemptionFeePercentage - treasuryFeePercentage)
        ).mulWad(treasuryFeePercentage);
    }
}
