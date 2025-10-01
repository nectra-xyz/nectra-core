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

    uint256 internal defaultInterestRate = 0.05 ether;
    uint256 internal defaultCollateral = 100 ether;

    uint256[] internal tokens;
    uint256[] internal interestRates;
    uint256[] internal debts;
    uint256[] internal collaterals;

    function setUp() public virtual override {
        super.setUp();

        // set array lengths
        assembly {
            sstore(tokens.slot, 4)
            sstore(interestRates.slot, 4)
            sstore(debts.slot, 4)
            sstore(collaterals.slot, 4)
        }

        (collaterals[0], debts[0], interestRates[0]) = (defaultCollateral, 10 ether, defaultInterestRate);
        (collaterals[1], debts[1], interestRates[1]) =
            (defaultCollateral, 85 ether, defaultInterestRate + systemParams.interestRateIncrement);
        (collaterals[2], debts[2], interestRates[2]) =
            (defaultCollateral, 20 ether, defaultInterestRate + systemParams.interestRateIncrement * 2);
        (collaterals[3], debts[3], interestRates[3]) =
            (defaultCollateral, 20 ether, defaultInterestRate + systemParams.interestRateIncrement * 3);

        for (uint256 i = 0; i < interestRates.length; i++) {
            nectra.storeSystemInterestRate(interestRates[i]);
            (tokens[i],,,,) =
                nectra.modifyPosition{value: collaterals[i]}(0, int256(collaterals[i]), int256(debts[i]), "");
        }

        nectraUSD.approve(address(nectra), type(uint256).max);
        // set system interest rate to default
        nectra.storeSystemInterestRate(defaultInterestRate);
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
                NectraLiquidate.NotEligibleForFullLiquidation.selector,
                type(uint256).max,
                systemParams.fullLiquidationRatio
            )
        );
        nectra.fullLiquidate(31337);
    }

    function test_should_revert_for_position_not_eligible_for_full_liquidation() public {
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokens[1]);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 cratio = collateral * collateralPrice / debt;

        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForFullLiquidation.selector, cratio, systemParams.fullLiquidationRatio
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
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);
    }

    function test_should_allow_full_liquidation_when_position_cratio_is_below_full_liquidation_ratio() public {
        uint256 positionIndex = 1;
        uint256 tokenId = tokens[positionIndex];
        uint256 interestRate = interestRates[positionIndex];
        uint256 collateral = collaterals[positionIndex];
        uint256 debt = debts[positionIndex];

        uint256 fullLiquidationPrice = systemParams.fullLiquidationRatio * debt / collateral;

        NectraLib.GlobalState memory globalStateBefore = nectra.getGlobalState();
        uint256 globalDebtBefore = nectraExternal.getGlobalDebt();
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(interestRate);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, interestRate);

        // check that position is correctly removed from bucket and global state
        uint256 globalDebtAfter = nectraExternal.getGlobalDebt();
        uint256 bucketDebtAfter = nectraExternal.getBucketDebt(interestRate);
        (NectraLib.BucketState memory bucketAfter, NectraLib.GlobalState memory globalStateAfter) =
            nectra.getBucketState(interestRate);

        uint256 totalDebtChange = debt + systemParams.fullLiquidationFee;
        uint256 expectedGlobalDebt = globalDebtBefore + systemParams.fullLiquidationFee;
        uint256 bucketUnrealizedLiquidatedDebt =
            totalDebtChange * bucketAfter.globalDebtShares / globalStateAfter.totalDebtShares;
        uint256 expectedBucketDebt = bucketDebtBefore - debt + bucketUnrealizedLiquidatedDebt;
        uint256 expectedCollateralPerShare = globalStateBefore.accumulatedLiquidatedCollateralPerShare
            + collateral.divWad(globalStateAfter.totalDebtShares);
        uint256 expectedDebtPerShare = globalStateBefore.accumulatedLiquidatedDebtPerShare
            + totalDebtChange.divWad(globalStateAfter.totalDebtShares);

        assertEq(globalDebtAfter, expectedGlobalDebt, "global debt not deducted correctly");
        assertEq(bucketDebtAfter, expectedBucketDebt, "bucket debt not deducted correctly");

        assertEq(
            globalStateAfter.accumulatedLiquidatedCollateralPerShare,
            expectedCollateralPerShare,
            "global collateral per share not updated correctly"
        );
        assertEq(
            globalStateAfter.accumulatedLiquidatedDebtPerShare,
            expectedDebtPerShare,
            "global debt per share not updated correctly"
        );

        // check that bucket and global state are correct after updatePosition is called
        nectra.updatePosition(tokenId);

        assertEq(nectraExternal.getGlobalDebt(), expectedGlobalDebt, "global debt not updated correctly");
        assertEq(nectraExternal.getBucketDebt(interestRate), expectedBucketDebt, "bucket debt not updated correctly");
    }

    function test_should_pay_liquidator_reward() public {
        uint256 tokenId = tokens[1];
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // check that the liquidator received the reward
        assertEq(nectraUSD.balanceOf(liquidator), systemParams.fullLiquidationFee);
    }

    function test_should_socialize_liquidator_reward_as_debt() public {
        uint256 tokenId = tokens[1];
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        uint256 globalDebtBefore = nectraExternal.getGlobalDebt();

        oracle.setCurrentPrice(fullLiquidationPrice);
        uint256 liquidatorBalanceBefore = nectraUSD.balanceOf(address(this));
        nectra.fullLiquidate(tokenId);

        // check that the liquidator reward is added to the global debt
        assertEq(
            nectraExternal.getGlobalDebt(),
            globalDebtBefore + systemParams.fullLiquidationFee,
            "debt should increase by the liquidator reward 1"
        );

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // Update 5% bucket to realize socialized debt and collateral
        nectra.updatePosition(tokens[0]);

        // check that the liquidator received the reward
        assertEq(
            nectraUSD.balanceOf(address(this)),
            liquidatorBalanceBefore + systemParams.fullLiquidationFee,
            "liquidator reward not added to liquidator balance"
        );
    }

    function test_should_realize_outstanding_interest_when_checking_cratio() public {
        uint256 tokenId = tokens[1];
        uint256 bucket = defaultInterestRate + systemParams.interestRateIncrement;
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        // calculate the time shift required to make the position eligible for full liquidation due to interest
        uint256 targetInterest = collateral.mulWad(collateralPrice).divWad(systemParams.fullLiquidationRatio) - debt;
        uint256 timeShift = targetInterest.divWad(bucket.mulWad(debt));
        uint256 targetTime = block.timestamp + (timeShift * 365 days / UNIT);

        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(bucket);
        uint256 expectedFeeRecipientBalance = nectraExternal.calculateInterest(
            bucketDebtBefore, bucket, targetTime - block.timestamp
        ) + nectraUSD.balanceOf(feeRecipient);

        // should revert because the interest is not accrued yet
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForFullLiquidation.selector,
                1411764705882352941,
                systemParams.fullLiquidationRatio
            )
        );
        nectra.fullLiquidate(tokenId);

        // warp to the target time to accrue enough interest to make the position eligible for full liquidation
        vm.warp(targetTime);

        // should not revert because the interest is realized
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // check that the fee recipient received the correct amount of interest
        assertEq(
            nectraUSD.balanceOf(feeRecipient), expectedFeeRecipientBalance, "fee recipient should receive the interest"
        );
    }

    function test_should_not_redistribute_back_into_liquidated_position_when_reopened() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = systemParams.fullLiquidationRatio * debt / collateral;

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // reopen the position
        nectra.modifyPosition{value: collateral}(tokenId, int256(collateral), int256(debt), "");

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId, collateral, debt, defaultInterestRate);
    }

    function test_should_not_socialise_into_new_position_when_opened_in_same_bucket() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // open new position in same bucket
        (uint256 tokenId2,,,,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), "");

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, collateral, debt, defaultInterestRate);
    }

    function test_should_not_socialise_into_new_position_when_opened_in_different_bucket() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // open new position in different bucket
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);
        (uint256 tokenId2,,,,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), "");

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, collateral, debt, defaultInterestRate + systemParams.interestRateIncrement);
    }

    function test_should_socialise_into_existing_position_in_same_bucket_when_updated() public {
        uint256 tokenId = tokens[1];
        uint256 tokenId2 = tokens[2];
        uint256 collateral2 = nectraExternal.getPositionCollateral(tokenId2);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // update position in same bucket
        (NectraLib.PositionState memory positionBefore, NectraLib.BucketState memory bucketBefore,) =
            nectra.getPositionState(tokenId2);
        uint256 bucket = defaultInterestRate + systemParams.interestRateIncrement * 2;
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(bucket);
        uint256 expectedDebt = bucketDebtBefore.mulWad(positionBefore.debtShares).divWad(bucketBefore.totalDebtShares);
        uint256 expectedCollateral =
            collateral2 + bucketBefore.accumulatedLiquidatedCollateralPerShare.mulWad(positionBefore.debtShares);

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, expectedCollateral, expectedDebt, bucket);
    }

    function test_should_socialise_into_existing_position_in_different_bucket_when_updated() public {
        uint256 tokenId = tokens[1];
        uint256 tokenId2 = tokens[3];
        uint256 collateral2 = nectraExternal.getPositionCollateral(tokenId2);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, defaultInterestRate + systemParams.interestRateIncrement);

        // restore price to normal
        oracle.setCurrentPrice(collateralPrice);

        // update position in different bucket
        (NectraLib.PositionState memory positionBefore, NectraLib.BucketState memory bucketBefore,) =
            nectra.getPositionState(tokenId2);
        uint256 bucket = defaultInterestRate + systemParams.interestRateIncrement * 3;
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(bucket);
        uint256 expectedDebt = bucketDebtBefore.mulWad(positionBefore.debtShares).divWad(bucketBefore.totalDebtShares);
        uint256 expectedCollateral =
            collateral2 + bucketBefore.accumulatedLiquidatedCollateralPerShare.mulWad(positionBefore.debtShares);

        // check that the position is reopened without redistribution of liquidated collateral or debt
        _checkPosition(tokenId2, expectedCollateral, expectedDebt, bucket);
    }

    function test_should_update_bucket_collateral_when_liquidating_full() public {
        uint256 tokenId = tokens[3];
        uint256 bucket = defaultInterestRate + systemParams.interestRateIncrement * 3;
        (uint256 collateral,,) = nectraExternal.getPosition(tokenId);

        uint256 fullLiquidationPrice = nectraExternal.getPositionFullLiquidationPrice(tokenId);
        (NectraLib.BucketState memory bucketBefore,) = nectra.getBucketState(bucket);
        uint256 expectedCollateral = bucketBefore.collateral - collateral;

        oracle.setCurrentPrice(fullLiquidationPrice);
        nectra.fullLiquidate(tokenId);

        // check that the position is fully liquidated
        _checkPosition(tokenId, 0, 0, bucket);

        // check that the bucket collateral is updated correctly
        (NectraLib.BucketState memory bucketAfter,) = nectra.getBucketState(bucket);
        assertEq(bucketAfter.collateral, expectedCollateral, "Bucket collateral is incorrect");
    }

    // Flash loan receiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
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
