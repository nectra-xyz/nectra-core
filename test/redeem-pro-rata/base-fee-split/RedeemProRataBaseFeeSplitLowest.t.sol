// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RedeemProRataBaseTest} from "test/redeem-pro-rata/RedeemProRataBase.t.sol";

/// @notice Test cases to confirm that when configured the redemption fee is split between
/// the bucket and the fee recipient.
/// @dev 100% of the fee should remain in the buffer bucket at all times.
contract RedeemProRataBaseFeeSplitLowestTest is RedeemProRataBaseTest {
    function setUp() public virtual override {
        systemParams.redemptionBaseFee = 0.01 ether; // 1% base fee
        systemParams.redemptionFeeTreasuryThreshold = 0.005 ether; // 0.5% threshold - so 0.6% upwards will be sent to treasury
        super.setUp();

        // restore system interest rate
        nectra.storeSystemInterestRate(interestRates[0]);
    }

    function _getExpectedFeePercentages()
        internal
        view
        returns (uint256 redemptionFeePercentage, uint256 treasuryFeePercentage, uint256 bucketFeePercentage)
    {
        // for the sake of simplicity we just use a large base fee with no scaling
        redemptionFeePercentage = systemParams.redemptionBaseFee;

        // cap the redemption fee to 100%
        if (redemptionFeePercentage > 1 ether) {
            redemptionFeePercentage = 1 ether;
        }

        // if the redemption fee exceeds the threshold, split the portion above to be sent to the
        // fee recipient and leave the portion below in the bucket.
        treasuryFeePercentage = redemptionFeePercentage > systemParams.redemptionFeeTreasuryThreshold
            ? redemptionFeePercentage - systemParams.redemptionFeeTreasuryThreshold
            : 0;

        bucketFeePercentage = redemptionFeePercentage - treasuryFeePercentage;
    }

    function test_redeem_AffectsBufferFirst_JustBelow() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether - 1;
        (uint256 redemptionFeePercentage,,) = _getExpectedFeePercentages();
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
        // confirm that the correct portion of the fee was left in the bucket
        // redeemer collateral and treasury fee are removed, leaving the bucket fee and surplus collateral
        uint256 expectedBucketRemaining = cBufBefore - expectedOutput;
        assertApproxEqRel(
            _collateral(bufferTokenId), expectedBucketRemaining, 1e11, "buffer collateral was not updated correctly"
        );
        // confirm that the correct portion of the fee was sent to the fee recipient
        assertApproxEqRel(address(feeRecipient).balance, 0, 1e11, "treasury fee was not sent to fee recipient");
    }

    function test_redeem_AffectsBufferFirst_Full() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether;
        (uint256 redemptionFeePercentage,,) = _getExpectedFeePercentages();
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
        // confirm that the correct portion of the fee was left in the bucket
        // redeemer collateral and treasury fee are removed, leaving the bucket fee and surplus collateral
        uint256 expectedBucketRemaining = cBufBefore - expectedOutput;
        assertApproxEqRel(
            _collateral(bufferTokenId), expectedBucketRemaining, 1e11, "buffer collateral was not updated correctly"
        );
        // confirm that the correct portion of the fee was sent to the fee recipient
        assertApproxEqRel(address(feeRecipient).balance, 0, 1e11, "treasury fee was not sent to fee recipient");
    }

    function test_redeem_AffectsBufferFirst_JustAbove() public {
        uint256 cBufBefore = _collateral(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;

        uint256 redemptionAmount = 100 ether + 1;
        (uint256 redemptionFeePercentage,,) = _getExpectedFeePercentages();
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
        // confirm that the correct portion of the fee was left in the bucket
        // redeemer collateral and treasury fee are removed, leaving the bucket fee and surplus collateral
        uint256 expectedBucketRemaining = cBufBefore - expectedOutput;
        assertApproxEqRel(
            _collateral(bufferTokenId), expectedBucketRemaining, 1e11, "buffer collateral was not updated correctly"
        );
        // confirm that the correct portion of the fee was sent to the fee recipient
        assertApproxEqRel(address(feeRecipient).balance, 0, 1e11, "treasury fee was not sent to fee recipient");
    }

    function test_redeem_ExceedBuffer_ProRataBetweenAtAndAbove() public {
        uint256 bufferCollateralBefore = _collateral(bufferTokenId);
        uint256[] memory collateralsBefore = _getCollaterals(tokens);
        uint256 bufferDebtBefore = _debt(bufferTokenId);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;
        uint256 feeRecipientInitialBalance = address(feeRecipient).balance;

        // Redeem 199: 100 from buffer, 99 from remaining buckets
        uint256 redemptionAmount = 199 ether;
        (uint256 redemptionFeePercentage, uint256 treasuryFeePercentage, uint256 bucketFeePercentage) =
            _getExpectedFeePercentages();
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
        expectedCollaterals[0] = collateralsBefore[0] - remainder * 3 * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[1] = collateralsBefore[1] - remainder * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[2] = collateralsBefore[2] - remainder * 2 * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[3] = collateralsBefore[3] - remainder * 2 * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[4] = collateralsBefore[4] - remainder * 2 * (UNIT - bucketFeePercentage) / price;

        _checkDebts(tokens, expectedDebts);
        _checkCollaterals(tokens, expectedCollaterals);
        // verify fee was charged to redeemer
        uint256 expectedOutput = redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(collateralRedeemed, expectedOutput, 1e11, "redemption fee was not charged correctly");
        assertEq(
            address(this).balance,
            redeemerInitialBalance + collateralRedeemed,
            "redeemer collateral received was not correct"
        );
        // verify that the correct portion of the fee was sent to the fee recipient
        uint256 expectedTreasuryOutput =
            feeRecipientInitialBalance + (redemptionAmount - bufferDebtBefore) * treasuryFeePercentage / price;
        assertApproxEqRel(
            address(feeRecipient).balance, expectedTreasuryOutput, 1e11, "treasury fee was not sent to fee recipient"
        );
    }

    function test_redeem_FullSystemRedemption() public {
        uint256 bufferCollateralBefore = _collateral(bufferTokenId);
        uint256 bufferDebtBefore = _debt(bufferTokenId);
        uint256[] memory collateralsBefore = _getCollaterals(tokens);
        uint256[] memory debtsBefore = _getDebts(tokens);
        uint256 redeemerInitialBalance = address(this).balance;
        uint256 feeRecipientInitialBalance = address(feeRecipient).balance;

        // Redeem full amount
        // need to redeem 1 wei less than total debt to avoid 100% fee
        uint256 redemptionAmount = 600 ether - 1;
        nectra.redeem(redemptionAmount, 0);

        // buffer should be fully redeemed
        assertEq(_debt(bufferTokenId), 0, "buffer should be fully redeemed");

        // other positions should be fully redeemed barring some rounding error
        uint256[] memory expectedDebts = new uint256[](5);
        expectedDebts[0] = 2;
        expectedDebts[1] = 2;
        expectedDebts[2] = 2;
        expectedDebts[3] = 2;
        expectedDebts[4] = 0;

        (uint256 redemptionFeePercentage, uint256 treasuryFeePercentage, uint256 bucketFeePercentage) =
            _getExpectedFeePercentages();
        uint256[] memory expectedCollaterals = new uint256[](5);
        expectedCollaterals[0] = collateralsBefore[0] - debtsBefore[0] * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[1] = collateralsBefore[1] - debtsBefore[1] * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[2] = collateralsBefore[2] - debtsBefore[2] * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[3] = collateralsBefore[3] - debtsBefore[3] * (UNIT - bucketFeePercentage) / price;
        expectedCollaterals[4] = collateralsBefore[4] - debtsBefore[4] * (UNIT - bucketFeePercentage) / price;

        _checkDebts(tokens, expectedDebts);

        uint256 expectedBufferCollateral =
            bufferCollateralBefore - bufferDebtBefore * (UNIT - redemptionFeePercentage) / price;
        assertEq(_collateral(bufferTokenId), expectedBufferCollateral, "buffer collateral was not updated correctly");
        _checkCollaterals(tokens, expectedCollaterals);

        // verify that the correct portion of the fee was charged to the redeemer
        uint256 expectedOutput = redeemerInitialBalance + redemptionAmount * (UNIT - redemptionFeePercentage) / price;
        assertApproxEqRel(address(this).balance, expectedOutput, 1e11, "redemption fee was not charged correctly");

        // check that the correct portion of the fee was sent to the fee recipient
        uint256 expectedTreasuryOutput =
            feeRecipientInitialBalance + (redemptionAmount - bufferDebtBefore) * treasuryFeePercentage / price;
        assertApproxEqRel(
            address(feeRecipient).balance, expectedTreasuryOutput, 1e11, "treasury fee was not sent to fee recipient"
        );

        // redeem the last wei to zero out the position
        // nectra.redeem(1, 0);
        // _checkCanWithdrawAllCollateral();
    }
}
