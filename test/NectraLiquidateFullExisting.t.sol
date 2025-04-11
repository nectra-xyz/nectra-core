// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";
import {NectraLiquidate} from "src/NectraLiquidate.sol";
import {NectraFlash} from "src/NectraFlash.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";

contract NectraLiquidateFullExistingTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    uint256[] internal tokens;
    uint256 internal defaultInterestRate = 0.05 ether;
    uint256 internal defaultCollateral = 100 ether;

    function setUp() public virtual override {
        super.setUp();

        uint256 tokenId;
        // Open positions with different interest rates

        (tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(10 ether), defaultInterestRate, ""
        );
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(85 ether), defaultInterestRate, ""
        );
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(20 ether), defaultInterestRate, ""
        );
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(20 ether), defaultInterestRate + cargs.interestRateIncrement, ""
        );
        tokens.push(tokenId);
    }

    // Flash mint and flash borrow should be locked
    function test_should_revert_when_called_with_flash_mint_and_flash_borrow() public {
        vm.expectRevert(abi.encodeWithSelector(NectraBase.FlashMintInProgress.selector));
        nectra.flashMint(address(this), 100 ether, "");

        vm.expectRevert(abi.encodeWithSelector(NectraBase.FlashBorrowInProgress.selector));
        nectra.flashBorrow(address(this), 100 ether, "");
    }

    // Revert permutations
    function test_should_revert_for_invalid_position_id() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForFullLiquidation.selector, type(uint256).max, cargs.fullLiquidationRatio
            )
        );
        nectra.fullLiquidate(31337);
    }

    function test_should_revert_for_position_not_eligible_for_full_liquidation() public {
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokens[1]);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 cratio = collateral * collateralPrice / debt;

        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForFullLiquidation.selector, cratio, cargs.fullLiquidationRatio
            )
        );
        nectra.fullLiquidate(tokens[1]);
    }

    function test_should_revert_when_oracle_price_is_stale() public {
        oracle.setStale(true);

        vm.expectRevert(abi.encodeWithSelector(NectraBase.InvalidCollateralPrice.selector));
        nectra.fullLiquidate(tokens[1]);
    }

    function test_should_allow_full_liquidation_when_position_cratio_equals_full_liquidation_ratio() public {
        uint256 tokenId = tokens[1];
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);
    }

    function test_should_allow_full_liquidation_when_position_cratio_is_below_full_liquidation_ratio() public {
        // uint256 tokenId = tokens[1];
        // (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        // uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        // uint256 fullLiquidationPrice = cargs.fullLiquidationRatio * (debt + closingFee) / collateral;

        // uint256 globalDebtBefore = nectraExternal.getGlobalDebt();
        // uint256 bucketDebtBefore = nectraExternal.getBucketDebt(defaultInterestRate);

        // oracle.setCurrentPrice(fullLiquidationPrice);
        // nectra.fullLiquidate(tokenId);

        // // check that the position is fully liquidated
        // _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // // check that position is correctly removed from bucket and global state
        // uint256 globalDebtAfter = nectraExternal.getGlobalDebt();
        // NectraLib.BucketState memory bucketAfter = nectra.getBucketState(defaultInterestRate);
        // uint256 bucketDebtAfter = nectraExternal.getBucketDebt(defaultInterestRate);

        // console2.log("closing Fee", closingFee);
        // console2.log("global debt before", globalDebtBefore);
        // uint256 expectedGlobalDebt = globalDebtBefore + closingFee + cargs.fullLiquidationFee;
        // uint256 expectedBucketDebt = bucketDebtBefore - debt + closingFee + cargs.fullLiquidationFee;
        // uint256 expectedCollateralPerShare = globalStateBefore.accumulatedLiquidatedCollateralPerShare + collateral.divWad(globalStateBefore.totalDebtShares);
        // uint256 expectedDebtPerShare = globalStateBefore.accumulatedLiquidatedDebtPerShare + (debt + cargs.fullLiquidationFee).divWad(globalStateBefore.totalDebtShares);

        // assertEq(globalStateAfter.debt, expectedGlobalDebt, "global debt not deducted correctly");
        // assertEq(bucketDebtAfter, expectedBucketDebt, "bucket debt not deducted correctly");
        // assertEq(globalStateAfter.accumulatedLiquidatedCollateralPerShare, expectedCollateralPerShare, "global collateral per share not updated correctly");
        // assertEq(globalStateAfter.accumulatedLiquidatedDebtPerShare, expectedDebtPerShare, "global debt per share not updated correctly");

        // // check that bucket and global state are updated correctly when updatePosition is called
        // nectra.updatePosition(tokenId);

        // NectraLib.GlobalState memory globalStateAfterUpdate = nectra.getGlobalState();
        // NectraLib.BucketState memory bucketAfterUpdate = nectra.getBucketState(defaultInterestRate);
        // uint256 bucketDebtAfterUpdate = nectraExternal.getBucketDebt(defaultInterestRate);

        // uint256 expectedGlobalDebtAfterUpdate = expectedGlobalDebt + debt + closingFee;
        // uint256 expectedBucketDebtAfterUpdate = expectedBucketDebt + expectedDebtPerShare.mulWad(bucketAfter.globalDebtShares);

        // assertEq(globalStateAfterUpdate.debt, expectedGlobalDebtAfterUpdate, "global debt not updated correctly");
        // assertEq(bucketDebtAfterUpdate, expectedBucketDebtAfterUpdate, "bucket debt not updated correctly");
    }

    function test_should_pay_liquidator_reward() public {
        uint256 tokenId = tokens[1];
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // check that the liquidator received the reward
        assertEq(nectraUSD.balanceOf(liquidator), cargs.fullLiquidationFee);
    }

    function test_should_socialize_liquidator_reward_as_debt() public {
        uint256 tokenId = tokens[1];
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        uint256 globalDebtBefore = nectraExternal.getGlobalDebt();

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the liquidator received the reward
        assertEq(
            nectraExternal.getGlobalDebt(),
            globalDebtBefore + cargs.fullLiquidationFee,
            "debt should increase by the liquidator reward"
        );

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // Update 5% bucket to realize socialized debt and collateral
        nectra.updatePosition(tokens[0]);

        // check that the liquidator received the reward
        // assertEq(nectra.getGlobalState().debt, globalStateBefore.debt + closingFee + cargs.fullLiquidationFee, "debt should increase by the liquidator reward");
    }

    function test_should_realize_outstanding_fees_when_checking_cratio() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        uint256 feeRecipientBalanceBefore = nectraUSD.balanceOf(feeRecipient);
        // Move position cratio to exactly the full liquidation ratio
        // with the closing fee realized. If the closing fee is > 0 and
        // is not considered, the position will not be eligible for full liquidation
        // when fullLiquidate is called.
        uint256 priceBeforeFullLiquidaition = cargs.fullLiquidationRatio * (debt + closingFee) / collateral;

        // change the price to force liquidation
        oracle.setCurrentPrice(priceBeforeFullLiquidaition);

        // Should allow full liquidation if outstanding fees are considered,
        // but revert if outstanding fees are not considered
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // check that the fee recipient received the fee
        assertEq(
            nectraUSD.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + closingFee,
            "fee recipient should receive the closing fee"
        );
    }

    function test_should_realize_outstanding_interest_when_checking_cratio() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        // calculate the time shift required to make the position eligible for full liquidation due to interest
        uint256 targetInterest =
            collateral.mulWad(collateralPrice).divWad(cargs.fullLiquidationRatio) - (debt + closingFee);
        uint256 timeShift = targetInterest.divWad(defaultInterestRate.mulWad(debt + closingFee));
        uint256 targetTime = block.timestamp + (timeShift * 365 days / UNIT);
        // calculate the expected interest to be paid to the fee recipient
        // NOTE: the closing fee is absorbed into the interest accrued due to the
        // time shift, so it is not added to the expected balance.

        (NectraLib.BucketState memory bucketBefore,) = nectra.getBucketState(defaultInterestRate);
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 expectedFeeRecipientBalance = nectraExternal.calculateInterest(
            bucketDebtBefore, defaultInterestRate, targetTime - block.timestamp
        ) + nectraUSD.balanceOf(feeRecipient);

        // should revert because the interest is not accrued yet
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForFullLiquidation.selector, 1411764705882352941, cargs.fullLiquidationRatio
            )
        );
        nectra.fullLiquidate(tokenId);

        // warp to the target time to accrue enough interest to make the position eligible for full liquidation
        vm.warp(targetTime);

        // should not revert because the interest is realized
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // check that the fee recipient received the correct amount of interest
        assertEq(
            nectraUSD.balanceOf(feeRecipient), expectedFeeRecipientBalance, "fee recipient should receive the interest"
        );
    }

    function test_should_not_redistribute_back_into_liquidated_position_when_reopened() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = cargs.fullLiquidationRatio * (debt + closingFee) / collateral;

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // reopen the position
        nectra.modifyPosition{value: collateral}(tokenId, int256(collateral), int256(debt), defaultInterestRate, "");

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId, collateral, debt, defaultInterestRate);
    }

    function test_should_not_socialise_into_new_position_when_opened_in_same_bucket() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // open new position in same bucket
        (uint256 tokenId2,,,,) =
            nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), defaultInterestRate, "");

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, collateral, debt, defaultInterestRate);
    }

    function test_should_not_socialise_into_new_position_when_opened_in_different_bucket() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // open new position in different bucket
        (uint256 tokenId2,,,,) = nectra.modifyPosition{value: collateral}(
            0, int256(collateral), int256(debt), defaultInterestRate + cargs.interestRateIncrement, ""
        );

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, collateral, debt, defaultInterestRate + cargs.interestRateIncrement);
    }

    function test_should_socialise_into_existing_position_in_same_bucket_when_updated() public {
        uint256 tokenId = tokens[1];
        uint256 tokenId2 = tokens[2];
        (uint256 collateral2,) = nectraExternal.getPosition(tokenId2);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // update position in same bucket
        (NectraLib.PositionState memory positionBefore, NectraLib.BucketState memory bucketBefore,) =
            nectra.getPositionState(tokenId2);
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 expectedDebt = bucketDebtBefore.mulWad(positionBefore.debtShares).divWad(bucketBefore.totalDebtShares);
        uint256 expectedCollateral =
            collateral2 + bucketBefore.accumulatedLiquidatedCollateralPerShare.mulWad(positionBefore.debtShares);

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, expectedCollateral, expectedDebt, defaultInterestRate);
    }

    function test_should_socialise_into_existing_position_in_different_bucket_when_updated() public {
        uint256 tokenId = tokens[1];
        uint256 tokenId2 = tokens[3];
        (uint256 collateral2,) = nectraExternal.getPosition(tokenId2);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // update position in different bucket
        (NectraLib.PositionState memory positionBefore, NectraLib.BucketState memory bucketBefore,) =
            nectra.getPositionState(tokenId2);
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(defaultInterestRate + cargs.interestRateIncrement);
        uint256 expectedDebt = bucketDebtBefore.mulWad(positionBefore.debtShares).divWad(bucketBefore.totalDebtShares);
        uint256 expectedCollateral =
            collateral2 + bucketBefore.accumulatedLiquidatedCollateralPerShare.mulWad(positionBefore.debtShares);

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, expectedCollateral, expectedDebt, defaultInterestRate + cargs.interestRateIncrement);
    }

    // Flash loan receiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        payable
        returns (bool)
    {
        // Basic checks for the flash loan receiver
        require(msg.sender == address(nectra), "Invalid caller");
        require(initiator == address(this), "Invalid initiator");
        require(asset == address(nectraUSD) || asset == address(0), "Invalid asset");

        nectra.fullLiquidate(tokens[1]);

        // Repay the flash loan -- assume enough assets are in the contract
        if (asset == address(nectraUSD)) {
            nectraUSD.approve(msg.sender, amount + premium);
        } else {
            nectra.repayFlashBorrow{value: amount + premium}();
        }

        return true;
    }
}
