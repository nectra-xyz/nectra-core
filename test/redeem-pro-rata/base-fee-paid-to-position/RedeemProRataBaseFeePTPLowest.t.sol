// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RedeemProRataBaseTest} from "test/redeem-pro-rata/RedeemProRataBase.t.sol";

contract RedeemProRataBaseFeePTPLowestTest is RedeemProRataBaseTest {
    function setUp() public virtual override {
        systemParams.redemptionBaseFee = 0.01 ether; // 1% base fee
        systemParams.redemptionFeeTreasuryThreshold = UNIT; // 100% fee goes to position
        super.setUp();

        // restore system interest rate
        nectra.storeSystemInterestRate(interestRates[0]);
    }

    function _getExpectedFeePercentage(uint256) internal view override returns (uint256) {
        return systemParams.redemptionBaseFee;
    }

    function test_redeem_AffectsBufferFirst_JustBelow() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether - 1;
        uint256 redemptionFeePercentage = _getExpectedFeePercentage(redemptionAmount);
        uint256 collateralRedeemed = nectra.redeem(redemptionAmount, 0);

        // buffer reduced ~99.99 ether, but will have 2 wei left due to rounding
        assertApproxEqRel(_debt(bufferTokenId), 2, 1e11, "buffer not redeemed first");
        // other positions unchanged
        _checkDebts(tokens, debtsBefore);
        // verify fee was charged to redeemer and was left in position
        uint256 expectedOutput = redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(collateralRedeemed, expectedOutput, 1e11, "redemption fee was not charged");
        assertApproxEqRel(
            address(this).balance,
            redeemerInitialBalance + collateralRedeemed,
            1e11,
            "collateral received was not correct"
        );
        assertApproxEqRel(
            _collateral(bufferTokenId), cBufBefore - expectedOutput, 1e11, "buffer collateral was not updated correctly"
        );
    }

    function test_redeem_AffectsBufferFirst_Full() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether;
        uint256 redemptionFeePercentage = _getExpectedFeePercentage(redemptionAmount);
        uint256 collateralRedeemed = nectra.redeem(redemptionAmount, 0);

        // buffer reduced ~99
        assertApproxEqRel(_debt(bufferTokenId), 0, 1e11, "buffer not redeemed first");
        // other positions unchanged
        _checkDebts(tokens, debtsBefore);
        // verify fee was charged to redeemer and was left in position
        uint256 expectedOutput = redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(collateralRedeemed, expectedOutput, 1e11, "redemption fee was not charged");
        assertApproxEqRel(
            address(this).balance,
            redeemerInitialBalance + collateralRedeemed,
            1e11,
            "collateral received was not correct"
        );
        assertApproxEqRel(
            _collateral(bufferTokenId), cBufBefore - expectedOutput, 1e11, "buffer collateral was not updated correctly"
        );
    }

    function test_redeem_AffectsBufferFirst_JustAbove() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether + 1;
        uint256 redemptionFeePercentage = _getExpectedFeePercentage(redemptionAmount);
        uint256 collateralRedeemed = nectra.redeem(redemptionAmount, 0);

        // buffer reduced ~99
        assertApproxEqRel(_debt(bufferTokenId), 0, 1e11, "buffer not redeemed first");
        // other positions unchanged
        _checkDebts(tokens, debtsBefore);
        // verify fee was charged to redeemer and was left in position
        uint256 expectedOutput = redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(collateralRedeemed, expectedOutput, 1e11, "redemption fee was not charged");
        assertApproxEqRel(
            address(this).balance,
            redeemerInitialBalance + collateralRedeemed,
            1e11,
            "collateral received was not correct"
        );
        assertApproxEqRel(
            _collateral(bufferTokenId), cBufBefore - expectedOutput, 1e11, "buffer collateral was not updated correctly"
        );
    }

    function test_redeem_ExceedBuffer_ProRataBetweenAtAndAbove() public {
        uint256 bufferCollateralBefore = _collateral(bufferTokenId);
        uint256[] memory collateralsBefore = _getCollaterals(tokens);
        uint256 bufferDebtBefore = _debt(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        // Redeem 199: 100 from buffer, 99 from remaining buckets
        uint256 redemptionAmount = 199 ether;
        uint256 redemptionFeePercentage = _getExpectedFeePercentage(redemptionAmount);
        uint256 collateralRedeemed = nectra.redeem(redemptionAmount, 0);

        // buffer should be fully redeemed
        assertEq(_debt(bufferTokenId), 0, "buffer should be fully redeemed");
        uint256 expectedBufferCollateral =
            bufferCollateralBefore - bufferDebtBefore * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(
            _collateral(bufferTokenId), expectedBufferCollateral, 1e11, "buffer collateral was not updated correctly"
        );

        // buckets should be updated correctly
        uint256[] memory expectedDebts = new uint256[](tokens.length);
        uint256 remainder = (redemptionAmount - bufferDebtBefore) / 10;
        expectedDebts[0] = debtsBefore[0] - remainder * 3;
        expectedDebts[1] = debtsBefore[1] - remainder;
        expectedDebts[2] = debtsBefore[2] - remainder * 2;
        expectedDebts[3] = debtsBefore[3] - remainder * 2;
        expectedDebts[4] = debtsBefore[4] - remainder * 2;

        uint256[] memory expectedCollaterals = new uint256[](tokens.length);
        expectedCollaterals[0] = collateralsBefore[0] - remainder * 3 * (UNIT - redemptionFeePercentage) / price;
        expectedCollaterals[1] = collateralsBefore[1] - remainder * (UNIT - redemptionFeePercentage) / price;
        expectedCollaterals[2] = collateralsBefore[2] - remainder * 2 * (UNIT - redemptionFeePercentage) / price;
        expectedCollaterals[3] = collateralsBefore[3] - remainder * 2 * (UNIT - redemptionFeePercentage) / price;
        expectedCollaterals[4] = collateralsBefore[4] - remainder * 2 * (UNIT - redemptionFeePercentage) / price;

        _checkDebts(tokens, expectedDebts);
        _checkCollaterals(tokens, expectedCollaterals);
        // verify fee was charged to redeemer
        uint256 expectedOutput = redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(collateralRedeemed, expectedOutput, 1e11, "redemption fee was not charged");
        assertEq(
            address(this).balance,
            redeemerInitialBalance + collateralRedeemed,
            "redeemer collateral received was not correct"
        );
    }

    function test_redeem_FullSystemRedemption() public {
        uint256 bufferCollateralBefore = _collateral(bufferTokenId);
        uint256[] memory collateralsBefore = _getCollaterals(tokens);

        // Redeem full amount
        // need to redeem 1 wei less than total debt to avoid 100% fee
        nectra.redeem(600 ether, 0);

        // buffer should be fully redeemed
        assertEq(_debt(bufferTokenId), 0, "buffer should be fully redeemed");

        // other positions should be fully redeemed
        uint256[] memory expectedDebts = new uint256[](5);
        expectedDebts[0] = 0;
        expectedDebts[1] = 0;
        expectedDebts[2] = 0;
        expectedDebts[3] = 0;
        expectedDebts[4] = 0;

        _checkDebts(tokens, expectedDebts);

        // redmeption fee == 100% for full redemption, ensure all collaterals are unchanged
        assertEq(_collateral(bufferTokenId), bufferCollateralBefore, "buffer collateral was not updated correctly");
        _checkCollaterals(tokens, collateralsBefore);
        _checkCanWithdrawAllCollateral();
    }
}
