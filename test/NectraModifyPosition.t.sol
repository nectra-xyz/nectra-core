// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console} from "test/NectraBase.t.sol";

import {IERC721} from "src/interfaces/IERC721.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {INectraNFT} from "src/interfaces/INectraNFT.sol";
import {INectra} from "src/interfaces/INectra.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {NectraLib} from "src/NectraLib.sol";

import {ModifyPositionReentrancy} from "test/helpers/ModifyPositionReentrancy.sol";

contract NectraModifyPositionTest is NectraBaseTest {
    uint256 defaultTokenId;

    uint256 defaultCollateral = 10_000 ether;
    uint256 defaultDebt = 5_000 ether;
    uint256 defaultInterestRate = 0.05 ether;

    address notOwner = makeAddr("notOwner");

    function setUp() public virtual override {
        systemParams.minimumInterestRate = 0.0001 ether;
        super.setUp();

        defaultInterestRate = nectra.getSystemInterestRate();

        // Create default position to test permission requirements
        (defaultTokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");
    }

    // Basic Requirements
    function test_should_fail_for_invalid_tokenId() public {
        vm.expectRevert(IERC721.TokenDoesNotExist.selector);
        nectra.modifyPosition(1337, int256(defaultCollateral), int256(defaultDebt), "");
    }

    function test_should_fail_for_invalid_low_interest_rate() public {
        vm.expectRevert(
            abi.encodeWithSelector(INectra.InterestRateTooLow.selector, 0 ether, systemParams.minimumInterestRate)
        );
        nectra.storeSystemInterestRate(0 ether);
    }

    function test_should_fail_for_invalid_high_interest_rate() public {
        vm.expectRevert(
            abi.encodeWithSelector(INectra.InterestRateTooHigh.selector, 101 ether, systemParams.maximumInterestRate)
        );
        nectra.storeSystemInterestRate(101 ether);
    }

    function test_should_fail_for_invalid_interest_rate_increment() public {
        vm.expectRevert(INectra.InvalidInterestRate.selector);
        nectra.storeSystemInterestRate(0.051234 ether);
    }

    function test_should_fail_for_below_minimum_deposit() public {
        uint256 belowMinimumDeposit = systemParams.minimumCollateral - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                INectra.MinimumDepositNotMet.selector, belowMinimumDeposit, systemParams.minimumCollateral
            )
        );
        nectra.modifyPosition{value: belowMinimumDeposit}(0, int256(belowMinimumDeposit), int256(defaultDebt), "");
    }

    function test_should_fail_for_below_minimum_debt() public {
        // calculate target position debt to be 1 wei below minimum debt
        uint256 belowMinimumDebt = systemParams.minimumDebt * UNIT / (UNIT + systemParams.openFeePercentage) - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                INectra.MinimumDebtNotMet.selector, systemParams.minimumDebt - 1, systemParams.minimumDebt
            )
        );
        nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(belowMinimumDebt), "");
    }

    function test_should_fail_when_close_but_not_withdraw() public {
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(defaultTokenId);
        nectraUSD.approve(address(nectra), debt);
        // attempt to repay all debt but not withdraw collateral
        vm.expectRevert(abi.encodeWithSelector(INectra.MinimumDebtNotMet.selector, 0, systemParams.minimumDebt));
        nectra.modifyPosition(defaultTokenId, 0, -int256(debt), "");
        // confirm that collateral and debt are unchanged
        _checkPosition(defaultTokenId, collateral, debt, defaultInterestRate);
    }

    function test_should_fail_when_borrow_passed_issuance_ratio() public {
        int256 excessiveDebt = 1_000_000_000_000_000_000 ether;

        // open new position with excessive debt
        vm.expectRevert(INectra.InsufficientCollateral.selector);
        nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), excessiveDebt, "");

        // modify existing position with excessive debt
        vm.expectRevert(INectra.InsufficientCollateral.selector);
        nectra.modifyPosition(defaultTokenId, 0, excessiveDebt, "");
    }

    // Permission Requirements
    function test_should_fail_when_caller_is_not_owner_or_approved_to_borrow() public {
        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to increase debt
        nectra.modifyPosition(defaultTokenId, int256(defaultCollateral), int256(defaultDebt + 1 ether), "");

        // confirm that debt was not changed
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_borrow() public {
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        // position owner can increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + UNIT, defaultInterestRate);
        // position owner should have received the borrowed NUSD
        assertEq(
            nectraUSD.balanceOf(address(this)),
            initialNUSDBalance + UNIT,
            "Position owner should have received borrowed NUSD"
        );

        // authorize notOwner to borrow
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Borrow);
        uint256 notOwnerNUSDBalanceBefore = nectraUSD.balanceOf(notOwner);

        vm.prank(notOwner);
        // notOwner can increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + 2 ether, defaultInterestRate);
        // owner should remain unchanged
        assertEq(
            nectraUSD.balanceOf(address(this)),
            initialNUSDBalance + UNIT,
            "Position owner should have received borrowed NUSD"
        );
        // notOwner should have received the borrowed NUSD
        assertEq(
            nectraUSD.balanceOf(notOwner),
            notOwnerNUSDBalanceBefore + UNIT,
            "Not owner should have received borrowed NUSD"
        );
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_repay() public {
        deal(address(nectraUSD), notOwner, UNIT);

        vm.startPrank(notOwner);
        nectraUSD.approve(address(nectra), UNIT);

        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to decrease debt
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        // confirm that debt was not changed
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_repay() public {
        // position owner can decrease debt
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT, defaultInterestRate);

        // authorize notOwner to repay
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Repay);
        deal(address(nectraUSD), notOwner, UNIT);

        vm.startPrank(notOwner);
        nectraUSD.approve(address(nectra), UNIT);

        // notOwner can decrease debt
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        // Note: during repayment, a portion of the closing fee is realized and added to the debt
        // the remainder is returned by calculateOutstandingFee. The sum of the realized amount and the remainder
        // equals the initial closing fee.
        uint256 expectedDebt = defaultDebt - 2 * UNIT;
        _checkPosition(defaultTokenId, defaultCollateral, expectedDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_deposit() public {
        deal(notOwner, 1 ether);

        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, "");
        // confirm that collateral was not changed
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_deposit() public {
        // position owner can increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral + UNIT, defaultDebt, defaultInterestRate);

        // authorize notOwner to deposit
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Deposit);
        deal(notOwner, UNIT);

        vm.prank(notOwner);
        // notOwner can increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral + 2 * UNIT, defaultDebt, defaultInterestRate);
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_withdraw() public {
        deal(notOwner, UNIT);

        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, "");
        // confirm that collateral was not changed
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_withdraw() public {
        uint256 initialBalance = address(this).balance;

        // position owner can withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral - UNIT, defaultDebt, defaultInterestRate);
        // position owner should have received the collateral
        assertEq(address(this).balance, initialBalance + UNIT, "Position owner should have received collateral");

        // authorize notOwner to withdraw
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Withdraw);
        deal(notOwner, UNIT);
        uint256 notOwnerBalanceBefore = address(notOwner).balance;

        vm.prank(notOwner);
        // notOwner can withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral - 2 * UNIT, defaultDebt, defaultInterestRate);

        // position owner should remain unchanged
        assertEq(address(this).balance, initialBalance + UNIT, "Position owner should have received collateral");
        // notOwner should have received the collateral
        assertEq(address(notOwner).balance, notOwnerBalanceBefore + UNIT, "Not owner should have received collateral");
    }

    function test_should_not_change_interest_rate_when_debt_is_decreasing() public {
        // set new interest rate
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);

        // position owner can decrease debt
        nectraUSD.approve(address(nectra), 1);
        nectra.modifyPosition(defaultTokenId, 0, -1, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - 1, defaultInterestRate);
    }

    function test_should_not_change_interest_rate_when_collateral_is_increasing() public {
        // set new interest rate
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);

        // position owner can increase collateral
        nectra.modifyPosition{value: 1}(defaultTokenId, 1, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral + 1, defaultDebt, defaultInterestRate);
    }

    function test_should_change_interest_rate_when_debt_is_increasing() public {
        // set new interest rate
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);

        // position owner can increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1, "");

        _checkPosition(
            defaultTokenId, defaultCollateral, defaultDebt + 1, defaultInterestRate + systemParams.interestRateIncrement
        );
    }

    function test_should_change_interest_rate_when_collateral_is_decreasing() public {
        // set new interest rate
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);

        // position owner can decrease collateral
        nectra.modifyPosition(defaultTokenId, -1, 0, "");

        _checkPosition(
            defaultTokenId, defaultCollateral - 1, defaultDebt, defaultInterestRate + systemParams.interestRateIncrement
        );
    }

    function test_should_fail_when_opening_position_with_collateral_mismatch_no_payment() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: 0 ether}(0, 1 ether, 0.5 ether, "");
    }

    function test_should_fail_when_opening_position_with_collateral_mismatch_under_paid() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: defaultCollateral - 1}(0, int256(defaultCollateral), int256(defaultDebt), "");
    }

    function test_should_fail_when_opening_position_with_collateral_mismatch_over_paid() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: defaultCollateral + 1}(0, int256(defaultCollateral), int256(defaultDebt), "");
    }

    // Debt Allowance
    function test_should_fail_when_repaying_position_debt_with_zero_allowance() public {
        nectraUSD.approve(address(nectra), 0);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        nectra.modifyPosition(defaultTokenId, 0, -1, "");
    }

    function test_should_fail_when_repaying_position_debt_with_insufficient_allowance() public {
        (, int256 debtDiff,,,) = nectra.quoteModifyPosition(defaultTokenId, 0, -2);

        nectraUSD.approve(address(nectra), uint256(-debtDiff) - 1);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        nectra.modifyPosition(defaultTokenId, 0, -2, "");
    }

    function test_should_succeed_when_repaying_position_debt_with_correct_allowance() public {
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT, defaultInterestRate);
        assertEq(nectraUSD.allowance(address(this), address(nectra)), 0, "Allowance not spent");
    }

    function test_should_succeed_when_repaying_position_debt_with_extra_allowance() public {
        uint256 extraAllowance = 10 ether;

        nectraUSD.approve(address(nectra), UNIT + extraAllowance);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT, defaultInterestRate);
        assertEq(nectraUSD.allowance(address(this), address(nectra)), extraAllowance, "Allowance not spent");
    }

    // Liquidation Socialization
    function test_should_not_socialize_to_new_position_in_same_bucket() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        // create new position in 5% bucket with default position
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);
    }

    function test_should_not_socialize_to_new_position_in_new_bucket() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        uint256 newInterestRate = 0.005 ether;

        // change system IR to 0.5% bucket
        nectra.storeSystemInterestRate(newInterestRate);

        // create new position in system IR bucket with default position
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        _checkPosition(tokenId, defaultCollateral, defaultDebt, newInterestRate);
    }

    function test_should_socialize_to_existing_position_before_depositing() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        (uint256 socializedCollateral, uint256 socializedDebt) =
            _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        // modify default position
        nectra.modifyPosition{value: 1 ether}(defaultTokenId, 1 ether, 0, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt = defaultDebt + socializedDebt;
        _checkPosition(
            defaultTokenId, defaultCollateral + socializedCollateral + UNIT, expectedDebt, defaultInterestRate
        );
    }

    function test_should_socialize_to_existing_position_before_withdrawing() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        (uint256 socializedCollateral, uint256 socializedDebt) =
            _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        // modify default position
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt = defaultDebt + socializedDebt;
        _checkPosition(
            defaultTokenId, defaultCollateral + socializedCollateral - UNIT, expectedDebt, defaultInterestRate
        );
    }

    function test_should_socialize_to_existing_position_before_borrowing() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        (uint256 socializedCollateral, uint256 socializedDebt) =
            _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        // modify default position
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt = defaultDebt + socializedDebt + UNIT;
        _checkPosition(defaultTokenId, defaultCollateral + socializedCollateral, expectedDebt, defaultInterestRate);
    }

    function test_should_socialize_to_existing_position_before_repaying() public {
        NectraLib.GlobalState memory globalState = nectra.getGlobalState();

        // accumulate liquidation collateral and debt in 5% bucket
        (uint256 socializedCollateral, uint256 socializedDebt) =
            _createAndForceLiquidatePositionInBucket(defaultInterestRate);

        // check that liquidation collateral and debt accumulators are updated
        globalState = nectra.getGlobalState();
        _checkBucketLiquidationAccumulators(
            defaultInterestRate,
            globalState.accumulatedLiquidatedCollateralPerShare,
            globalState.accumulatedLiquidatedDebtPerShare
        );

        // modify default position
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        // confirm the position has deducted the repaid debt, absorbed the socialized debt.
        uint256 expectedDebt = defaultDebt + socializedDebt - UNIT;
        _checkPosition(defaultTokenId, defaultCollateral + socializedCollateral, expectedDebt, defaultInterestRate);
    }

    // Success Cases (Full checks)
    function test_should_succeed_when_increasing_debt() public {
        // increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1234 ether, "");

        // confirm position state is updated
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + 1234 ether, defaultInterestRate);
    }

    function test_should_succeed_when_decreasing_debt() public {
        nectraUSD.approve(address(nectra), 567 ether);

        // decrease debt
        nectra.modifyPosition(defaultTokenId, 0, -567 ether, "");

        // confirm position state is updated
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - 567 ether, defaultInterestRate);
    }

    // Redeemed collateral socialization
    function test_should_not_socialize_redeemed_collateral_to_new_position_in_same_bucket() public {
        // increase redemption accumulator for 0.5% bucket
        _createAndFullyRedeemPosition();

        // create new position in 0.5% bucket with default position size
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm accumulated redeemed collateral is not socialized to new position
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);
    }

    function test_should_not_socialize_redeemed_collateral_to_new_position_in_new_bucket() public {
        // accumulate liquidation collateral and debt in 5% bucket
        _createAndFullyRedeemPosition();

        uint256 interestRate = 0.1 ether;

        // change system IR to 0.5% bucket
        nectra.storeSystemInterestRate(interestRate);

        // create new position in 5% bucket with default position
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm accumulated redeemed collateral is not socialized to new position
        _checkPosition(tokenId, defaultCollateral, defaultDebt, interestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_closing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        uint256 collateralBalanceBefore = address(this).balance;
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));

        // close position
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(tokenId, -int256(collateral), -int256(debt), "");

        // confirm position is correct after closing
        _checkPosition(tokenId, 0, 0, defaultInterestRate);

        // confirm transfer amounts are correct
        assertApproxEqRel(
            address(this).balance - collateralBalanceBefore, collateral, 1e11, "Incorrect collateral received"
        );
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)), debt, "Incorrect debt paid");
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_repaying() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        // repay debt
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(tokenId, 0, -1 ether, "");

        // confirm position is correct after repaying
        _checkPosition(tokenId, collateral, debt - UNIT, defaultInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_borrowing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        // borrow debt
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition(tokenId, 0, 1 ether, "");

        // Note:when borrowing the outstanding fee is increased by
        // the change amount multiplied by the open fee percentage
        uint256 newFee = UNIT * systemParams.openFeePercentage / UNIT;
        _checkPosition(tokenId, collateral, debt + UNIT + newFee, defaultInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_depositing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        // deposit collateral
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition{value: 1 ether}(tokenId, 1 ether, 0, "");

        // confirm position is correct after depositing
        _checkPosition(tokenId, collateral + UNIT, debt, defaultInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_withdrawing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        // withdraw collateral
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition(tokenId, -1 ether, 0, "");

        // confirm position is correct after withdrawing
        _checkPosition(tokenId, collateral - UNIT, debt, defaultInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_increasing_interest_rate() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct before redemption
        _checkPosition(tokenId, defaultCollateral, defaultDebt, defaultInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(defaultInterestRate);
        uint256 positionDebtBeforeRedemption = nectraExternal.getPositionDebt(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, defaultInterestRate);

        // increase interest rate (must increase debt)
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);
        nectra.modifyPosition(tokenId, 0, 1, "");

        // confirm position is correct after increasing interest rate
        _checkPosition(
            tokenId,
            collateralAfterRedemption,
            debtAfterRedemption + 1,
            defaultInterestRate + systemParams.interestRateIncrement
        );
    }

    function test_migrating_to_a_bucket_with_a_new_epoch_should_work() public {
        nectra.storeSystemInterestRate(defaultInterestRate + systemParams.interestRateIncrement);
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // fully redeem the first bucket
        _createAndFullyRedeemPosition();

        // migrate position to new epoch (must increase debt)
        nectra.storeSystemInterestRate(defaultInterestRate);
        nectra.modifyPosition(tokenId, 0, 1, "");

        // confirm position is correct after migration
        _checkPosition(tokenId, defaultCollateral, defaultDebt + 1, defaultInterestRate);
    }

    function test_migrating_to_a_bucket_should_change_bucket_collateral() public {
        uint256 initialBucket = defaultInterestRate + 0.5 ether;
        uint256 newBucket = initialBucket + systemParams.interestRateIncrement;

        nectra.storeSystemInterestRate(initialBucket);
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // get both bucket collateral
        (NectraLib.BucketState memory initialBucketState,) = nectra.getBucketState(initialBucket);
        (NectraLib.BucketState memory newBucketState,) = nectra.getBucketState(newBucket);

        // check that the bucket collateral has changed
        assertEq(initialBucketState.collateral, defaultCollateral, "Initial bucket collateral is incorrect");
        assertEq(newBucketState.collateral, 0, "New bucket collateral is incorrect");

        // migrate position to new bucket (must increase debt)
        nectra.storeSystemInterestRate(newBucket);
        nectra.modifyPosition(tokenId, 0, 1, "");

        // confirm bucket collateral is correct after migration
        (initialBucketState,) = nectra.getBucketState(initialBucket);
        (newBucketState,) = nectra.getBucketState(newBucket);

        assertEq(initialBucketState.collateral, 0, "Initial bucket collateral has not changed");
        assertEq(newBucketState.collateral, defaultCollateral, "New bucket collateral has not changed");
    }

    // withdraw should be reentrant safe
    function test_should_be_reentrant_safe() public {
        // create position
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: defaultCollateral}(0, int256(defaultCollateral), int256(defaultDebt), "");

        // confirm position is correct
        uint256 totalDebt = defaultDebt;
        _checkPosition(tokenId, defaultCollateral, totalDebt, defaultInterestRate);

        // Create reentrancy helper
        ModifyPositionReentrancy reentrancyHelper = new ModifyPositionReentrancy(nectra, nectraUSD);
        nectraNFT.authorize(tokenId, address(reentrancyHelper), NectraNFT.Permission.Borrow);
        nectraNFT.authorize(tokenId, address(reentrancyHelper), NectraNFT.Permission.Repay);
        nectraNFT.authorize(tokenId, address(reentrancyHelper), NectraNFT.Permission.Deposit);
        nectraNFT.authorize(tokenId, address(reentrancyHelper), NectraNFT.Permission.Withdraw);

        uint256 balanceBefore = address(reentrancyHelper).balance;

        // Call modifyPosition with reentrancy helper
        nectraUSD.transfer(address(reentrancyHelper), totalDebt);
        // This call should still succeed but the contract should not receive more collateral than what was in the position.
        reentrancyHelper.modifyPosition(tokenId, defaultCollateral, totalDebt, defaultInterestRate, totalDebt);

        assertEq(address(reentrancyHelper).balance, balanceBefore + defaultCollateral, "Incorrect collateral received");
    }

    // stale Oracle
    function test_should_fail_when_borrowing_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to increase debt
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(defaultTokenId, int256(defaultCollateral), int256(defaultDebt + 1), "");
    }

    function test_should_fail_when_withdrawing_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to decrease collateral
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(defaultTokenId, int256(defaultCollateral - 1), int256(defaultDebt), "");
    }

    function test_should_fail_when_changing_interest_rate_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to increase interest rate
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(defaultTokenId, int256(defaultCollateral), int256(defaultDebt), "");

        // position owner try to decrease interest rate
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(defaultTokenId, int256(defaultCollateral), int256(defaultDebt), "");
    }

    function test_should_allow_repaying_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to repay debt
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT, defaultInterestRate);
    }

    function test_should_allow_depositing_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to deposit collateral
        nectra.modifyPosition{value: 1 ether}(defaultTokenId, 1 ether, 0, "");

        _checkPosition(defaultTokenId, defaultCollateral + 1 ether, defaultDebt, defaultInterestRate);
    }

    function test_should_allow_closing_with_stale_oracle() public {
        oracle.setStale(true);
        uint256 collateralBalanceBefore = address(this).balance;
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(defaultTokenId);

        // position owner try to close position
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(defaultTokenId, -int256(collateral), -int256(debt), "");

        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm transfer amounts are correct
        assertEq(address(this).balance - collateralBalanceBefore, collateral, "Incorrect collateral received");
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)), debt, "Incorrect debt paid");
    }

    // Amount caps
    function test_should_cap_withdrawal_amount_at_available_collateral() public {
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(defaultTokenId);
        uint256 collateralBalanceBefore = address(this).balance;

        // close position but withdraw more collateral than what is available
        deal(address(nectraUSD), address(this), debt);
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(defaultTokenId, -int256(collateral + 10 ether), -int256(debt), "");

        // confirm position is correct
        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm collateral is correct
        assertEq(address(this).balance - collateralBalanceBefore, collateral, "Incorrect collateral received");
    }

    function test_should_cap_repayment_amount_at_available_debt() public {
        (uint256 collateral, uint256 debt,) = nectraExternal.getPosition(defaultTokenId);

        deal(address(nectraUSD), address(this), debt * 2);
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));

        // close position but repay more debt than what is available
        nectraUSD.approve(address(nectra), debt * 2);
        nectra.modifyPosition(defaultTokenId, -int256(collateral), -int256(debt * 2), "");

        // confirm position is correct
        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm collateral is correct
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)), debt, "Incorrect debt paid");
    }

    function _createAndForceLiquidatePosition() internal {
        (uint256 initialPrice,) = oracle.getLatestPrice();
        uint256 collateralAmount = 1000 ether;
        uint256 debtAtIssuance = collateralAmount * initialPrice
            / (systemParams.issuanceRatio * (UNIT + systemParams.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: collateralAmount}(0, int256(collateralAmount), int256(debtAtIssuance), "");

        // move price to force liquidation price
        uint256 forceLiquidationPrice = debtAtIssuance * systemParams.fullLiquidationRatio / collateralAmount;
        oracle.setCurrentPrice(forceLiquidationPrice);

        // liquidate position
        nectra.fullLiquidate(tokenId);

        // return price to initial price
        oracle.setCurrentPrice(initialPrice);
    }

    function _createAndForceLiquidatePositionInBucket(uint256 interestRate)
        internal
        returns (uint256 socializedCollateral, uint256 socializedDebt)
    {
        (uint256 initialPrice,) = oracle.getLatestPrice();
        socializedCollateral = 1000 ether;
        // calculate debt amount at issuance. It must exclude the opening fee because that will be added by the system
        // if it is not excluded the resultant cratio will be below the issuance ratio.
        socializedDebt = socializedCollateral * initialPrice
            / (systemParams.issuanceRatio * (UNIT + systemParams.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: socializedCollateral}(
            0, int256(socializedCollateral), int256(socializedDebt), ""
        );

        // move price to force liquidation price
        uint256 forceLiquidationPrice = socializedDebt * systemParams.fullLiquidationRatio / socializedCollateral;
        oracle.setCurrentPrice(forceLiquidationPrice);

        // liquidate position
        nectra.fullLiquidate(tokenId);

        // return price to initial price
        oracle.setCurrentPrice(initialPrice);

        // increase socialized debt by closing fee and full liquidation fee that were also socialized
        socializedDebt += systemParams.fullLiquidationFee;
    }

    function _createAndForceLiquidatePositionInBucketWithCollateral(uint256 interestRate, uint256 collateralAmount)
        internal
    {
        (uint256 initialPrice,) = oracle.getLatestPrice();
        uint256 debtAtIssuance = collateralAmount * initialPrice
            / (systemParams.issuanceRatio * (UNIT + systemParams.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) =
            nectra.modifyPosition{value: collateralAmount}(0, int256(collateralAmount), int256(debtAtIssuance), "");

        // move price to force liquidation price
        uint256 forceLiquidationPrice = debtAtIssuance * systemParams.fullLiquidationRatio / collateralAmount;
        oracle.setCurrentPrice(forceLiquidationPrice);

        // liquidate position
        nectra.fullLiquidate(tokenId);

        // return price to initial price
        oracle.setCurrentPrice(initialPrice);
    }

    function _createAndFullyRedeemPosition() internal returns (uint256 redeemedCollateral, uint256 redeemedDebt) {
        uint256 collateral = 1000 ether;
        redeemedDebt = 500 ether;
        nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(redeemedDebt), "");

        // calculate redeemed collateral
        (uint256 price,) = oracle.getLatestPrice();
        redeemedCollateral = redeemedDebt * UNIT / price;
        // redemption fee rounds up by 1 wei
        uint256 redemptionFeePercentage = nectra.getRedemptionFee(redeemedDebt) + 1;
        uint256 redemptionTreasuryFeePercentage = 0;

        // split fee between treasury and positions
        if (redemptionFeePercentage > systemParams.redemptionFeeTreasuryThreshold) {
            redemptionTreasuryFeePercentage = redemptionFeePercentage - systemParams.redemptionFeeTreasuryThreshold;
            redemptionFeePercentage = systemParams.redemptionFeeTreasuryThreshold;
        }

        // the amount redeemed from the positions is the total less the treasury split
        redeemedCollateral -= redeemedCollateral * redemptionFeePercentage / UNIT;

        // redeem position with slippage protection
        nectraUSD.approve(address(nectra), redeemedDebt);
        // minAmountOut should deduct the entire redemption fee
        nectra.redeem(redeemedDebt, redeemedCollateral - redeemedCollateral * redemptionFeePercentage / UNIT);
    }
}
