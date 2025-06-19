// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

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
        super.setUp();

        // Create default position to test permission requirements
        (defaultTokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, ""
        );
    }

    // Basic Requirements
    function test_should_fail_for_invalid_tokenId() public {
        vm.expectRevert(IERC721.TokenDoesNotExist.selector);
        nectra.modifyPosition(1337, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, "");
    }

    function test_should_fail_for_invalid_low_interest_rate() public {
        vm.expectRevert(abi.encodeWithSelector(INectra.InterestRateTooLow.selector, 0 ether, cargs.minimumInterestRate));
        nectra.modifyPosition(0, int256(defaultCollateral), int256(defaultDebt), 0 ether, "");
    }

    function test_should_fail_for_invalid_high_interest_rate() public {
        vm.expectRevert(
            abi.encodeWithSelector(INectra.InterestRateTooHigh.selector, 101 ether, cargs.maximumInterestRate)
        );
        nectra.modifyPosition(0, int256(defaultCollateral), int256(defaultDebt), 101 ether, "");
    }

    function test_should_fail_for_invalid_interest_rate_increment() public {
        vm.expectRevert(INectra.InvalidInterestRate.selector);
        nectra.modifyPosition(0, int256(defaultCollateral), int256(defaultDebt), 0.051234 ether, "");
    }

    function test_should_fail_for_below_minimum_deposit() public {
        uint256 belowMinimumDeposit = cargs.minimumCollateral - 1;
        vm.expectRevert(
            abi.encodeWithSelector(INectra.MinimumDepositNotMet.selector, belowMinimumDeposit, cargs.minimumCollateral)
        );
        nectra.modifyPosition{value: belowMinimumDeposit}(
            0, int256(belowMinimumDeposit), int256(defaultDebt), defaultInterestRate, ""
        );
    }

    function test_should_fail_for_below_minimum_debt() public {
        // calculate target position debt to be 1 wei below minimum debt
        uint256 belowMinimumDebt = cargs.minimumDebt * UNIT / (UNIT + cargs.openFeePercentage) - 1;

        vm.expectRevert(
            abi.encodeWithSelector(INectra.MinimumDebtNotMet.selector, cargs.minimumDebt - 1, cargs.minimumDebt)
        );
        nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(belowMinimumDebt), defaultInterestRate, ""
        );
    }

    function test_should_fail_when_close_but_not_withdraw() public {
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(defaultTokenId);
        nectraUSD.approve(address(nectra), debt);
        // attempt to repay all debt but not withdraw collateral
        vm.expectRevert(abi.encodeWithSelector(INectra.MinimumDebtNotMet.selector, 0, cargs.minimumDebt));
        nectra.modifyPosition(defaultTokenId, 0, -int256(debt), defaultInterestRate, "");
        // confirm that collateral and debt are unchanged
        _checkPosition(defaultTokenId, collateral, debt, defaultInterestRate);
    }

    function test_should_fail_when_borrow_passed_issuance_ratio() public {
        int256 excessiveDebt = 1_000_000_000_000_000_000 ether;

        // open new position with excessive debt
        vm.expectRevert(INectra.InsufficientCollateral.selector);
        nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), excessiveDebt, defaultInterestRate, ""
        );

        // modify existing position with excessive debt
        vm.expectRevert(INectra.InsufficientCollateral.selector);
        nectra.modifyPosition(defaultTokenId, 0, excessiveDebt, defaultInterestRate, "");
    }

    // Permission Requirements
    function test_should_fail_when_caller_is_not_owner_or_approved_to_borrow() public {
        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to increase debt
        nectra.modifyPosition(
            defaultTokenId, int256(defaultCollateral), int256(defaultDebt + 1 ether), defaultInterestRate, ""
        );
        // confirm that debt was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_borrow() public {
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));

        // position owner can increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, defaultInterestRate, "");

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + UNIT + closingFee, defaultInterestRate);
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
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, defaultInterestRate, "");

        closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + 2 ether + closingFee, defaultInterestRate);
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
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");
        // confirm that debt was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_repay() public {
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        // position owner can decrease debt
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT + closingFee, defaultInterestRate);

        // authorize notOwner to repay
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Repay);
        deal(address(nectraUSD), notOwner, UNIT);

        vm.startPrank(notOwner);
        nectraUSD.approve(address(nectra), UNIT);

        // notOwner can decrease debt
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        // Note: during repayment, a portion of the closing fee is realized and added to the debt
        // the remainder is returned by calculateOutstandingFee. The sum of the realized amount and the remainder
        // equals the initial closing fee.
        uint256 expectedDebt = defaultDebt + closingFee - 2 * UNIT;
        _checkPosition(defaultTokenId, defaultCollateral, expectedDebt, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_deposit() public {
        deal(notOwner, 1 ether);

        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, defaultInterestRate, "");
        // confirm that collateral was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_deposit() public {
        // position owner can increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, defaultInterestRate, "");

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral + UNIT, defaultDebt + closingFee, defaultInterestRate);

        // authorize notOwner to deposit
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Deposit);
        deal(notOwner, UNIT);

        vm.prank(notOwner);
        // notOwner can increase collateral
        nectra.modifyPosition{value: UNIT}(defaultTokenId, 1 ether, 0, defaultInterestRate, "");

        closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral + 2 * UNIT, defaultDebt + closingFee, defaultInterestRate);
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_withdraw() public {
        deal(notOwner, UNIT);

        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, defaultInterestRate, "");
        // confirm that collateral was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_withdraw() public {
        uint256 initialBalance = address(this).balance;

        // position owner can withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, defaultInterestRate, "");

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral - UNIT, defaultDebt + closingFee, defaultInterestRate);
        // position owner should have received the collateral
        assertEq(address(this).balance, initialBalance + UNIT, "Position owner should have received collateral");

        // authorize notOwner to withdraw
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.Withdraw);
        deal(notOwner, UNIT);
        uint256 notOwnerBalanceBefore = address(notOwner).balance;

        vm.prank(notOwner);
        // notOwner can withdraw collateral
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, defaultInterestRate, "");

        closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral - 2 * UNIT, defaultDebt + closingFee, defaultInterestRate);

        // position owner should remain unchanged
        assertEq(address(this).balance, initialBalance + UNIT, "Position owner should have received collateral");
        // notOwner should have received the collateral
        assertEq(address(notOwner).balance, notOwnerBalanceBefore + UNIT, "Not owner should have received collateral");
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_increase_interest_rate() public {
        deal(address(nectraUSD), notOwner, UNIT);

        vm.startPrank(notOwner);
        nectraUSD.approve(address(nectra), UNIT);

        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to increase interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate + cargs.interestRateIncrement, "");
        // confirm that interest rate was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_increase_interest_rate() public {
        // position owner can increase interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate + cargs.interestRateIncrement, "");

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(
            defaultTokenId,
            defaultCollateral,
            defaultDebt + closingFee,
            defaultInterestRate + cargs.interestRateIncrement
        );

        // authorize notOwner to increase interest rate
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.AdjustInterest);

        vm.startPrank(notOwner);
        // notOwner can increase interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate + 2 * cargs.interestRateIncrement, "");

        closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        _checkPosition(
            defaultTokenId,
            defaultCollateral,
            defaultDebt + closingFee,
            defaultInterestRate + 2 * cargs.interestRateIncrement
        );
        vm.stopPrank();
    }

    function test_should_fail_when_caller_is_not_owner_or_approved_to_decrease_interest_rate() public {
        vm.startPrank(notOwner);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        // attempt to decrease interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate - cargs.interestRateIncrement, "");
        // confirm that interest rate was not changed
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
        vm.stopPrank();
    }

    function test_should_pass_when_caller_is_owner_or_approved_to_decrease_interest_rate() public {
        (NectraLib.PositionState memory positionState,,) = nectra.getPositionState(defaultTokenId);
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        // position owner can decrease interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate - cargs.interestRateIncrement, "");

        _checkPosition(
            defaultTokenId,
            defaultCollateral,
            defaultDebt + closingFee,
            defaultInterestRate - cargs.interestRateIncrement
        );

        // authorize notOwner to increase interest rate
        nectraNFT.authorize(defaultTokenId, notOwner, NectraNFT.Permission.AdjustInterest);

        vm.startPrank(notOwner);
        // Should realize a new closing fee when decreasing interest rate further
        closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        // notOwner can decrease interest rate
        nectra.modifyPosition(defaultTokenId, 0, 0, defaultInterestRate - 2 * cargs.interestRateIncrement, "");

        _checkPosition(
            defaultTokenId,
            defaultCollateral,
            defaultDebt + closingFee,
            defaultInterestRate - 2 * cargs.interestRateIncrement
        );
        vm.stopPrank();
    }

    // Collateral Mismatch
    function test_should_fail_when_opening_position_with_collateral_mismatch_no_payment() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: 0 ether}(0, 1 ether, 0.5 ether, defaultInterestRate, "");
    }

    function test_should_fail_when_opening_position_with_collateral_mismatch_under_paid() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: defaultCollateral - 1}(
            0, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, ""
        );
    }

    function test_should_fail_when_opening_position_with_collateral_mismatch_over_paid() public {
        vm.expectRevert(INectra.CollateralMismatch.selector);
        nectra.modifyPosition{value: defaultCollateral + 1}(
            0, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, ""
        );
    }

    // Debt Allowance
    function test_should_fail_when_repaying_position_debt_with_zero_allowance() public {
        nectraUSD.approve(address(nectra), 0);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        nectra.modifyPosition(defaultTokenId, 0, -1, defaultInterestRate, "");
    }

    function test_should_fail_when_repaying_position_debt_with_insufficient_allowance() public {
        (, int256 debtDiff,,) = nectra.quoteModifyPosition(defaultTokenId, 0, -2, defaultInterestRate);

        nectraUSD.approve(address(nectra), uint256(-debtDiff) - 1);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        nectra.modifyPosition(defaultTokenId, 0, -2, defaultInterestRate, "");
    }

    function test_should_succeed_when_repaying_position_debt_with_correct_allowance() public {
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT + closingFee, defaultInterestRate);
        assertEq(nectraUSD.allowance(address(this), address(nectra)), 0, "Allowance not spent");
    }

    function test_should_succeed_when_repaying_position_debt_with_extra_allowance() public {
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        uint256 extraAllowance = 10 ether;

        nectraUSD.approve(address(nectra), UNIT + extraAllowance);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT + closingFee, defaultInterestRate);
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
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, ""
        );

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, defaultInterestRate);
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

        // create new position in 0.5% bucket with default position
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);
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
        nectra.modifyPosition{value: 1 ether}(defaultTokenId, 1 ether, 0, defaultInterestRate, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt = defaultDebt + socializedDebt + nectraExternal.getPositionOutstandingFee(defaultTokenId);
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
        nectra.modifyPosition(defaultTokenId, -1 ether, 0, defaultInterestRate, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt = defaultDebt + socializedDebt + nectraExternal.getPositionOutstandingFee(defaultTokenId);
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
        nectra.modifyPosition(defaultTokenId, 0, 1 ether, defaultInterestRate, "");

        // confirm accumulated liquidation collateral and debt are not socialized to new position
        uint256 expectedDebt =
            defaultDebt + socializedDebt + UNIT + nectraExternal.getPositionOutstandingFee(defaultTokenId);
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
        uint256 closingFeeBefore = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        // confirm the position has deducted the repaid debt, absorbed the socialized debt and still accounts
        // for the closing fee. Note: a portion of the closing fee was realized and added to the debt, the remainder
        // is returned by calculateOutstandingFee. The sum of the realized amount and the remainder equals the initial closing fee.
        uint256 expectedDebt = defaultDebt + socializedDebt - UNIT + closingFeeBefore;
        _checkPosition(defaultTokenId, defaultCollateral + socializedCollateral, expectedDebt, defaultInterestRate);
    }

    // Success Cases (Full checks)
    function test_should_succeed_when_increasing_debt() public {
        // increase debt
        nectra.modifyPosition(defaultTokenId, 0, 1234 ether, defaultInterestRate, "");

        // confirm position state is updated
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt + 1234 ether + closingFee, defaultInterestRate);
    }

    function test_should_succeed_when_decreasing_debt() public {
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        nectraUSD.approve(address(nectra), 567 ether);

        // decrease debt
        nectra.modifyPosition(defaultTokenId, 0, -567 ether, defaultInterestRate, "");

        // confirm position state is updated
        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - 567 ether + closingFee, defaultInterestRate);
    }

    // function test_should_apply_open_fee_equally_even_debt_is_increased_or_initally_large() public {
    //     uint256[] memory tokenIds = new uint256[](2);

    //     // create first position
    //     (tokenIds[0],, ,,) = nectra.modifyPosition{value: defaultCollateral}(0, defaultCollateral, defaultDebt, defaultInterestRate, "");

    //     // create second position
    //     (tokenIds[1],, ,,) = nectra.modifyPosition{value: defaultCollateral}(0, defaultCollateral, defaultDebt / 2, defaultInterestRate, "");

    //     // Fast forward 6 months
    //     vm.warp(vm.getBlockTimestamp() + (365 days / 2));

    //     // increase debt on second position
    //     (, int256 debtDiff,,) = nectra.quoteModifyPosition(tokenIds[1], defaultCollateral, defaultDebt, defaultInterestRate);
    //     // nectraUSD.approve(address(nectra), uint256(-debtDiff));
    //     nectra.modifyPosition(tokenIds[1], defaultCollateral, defaultDebt, defaultInterestRate, "");

    //     // confirm positions are equal
    //     uint256 expectedDebt = defaultDebt + NectraLib.calculateInterest(defaultDebt, defaultInterestRate, 365 days / 2);
    //     _checkPosition(tokenIds[0], defaultCollateral, expectedDebt, defaultInterestRate);
    //     _checkPosition(tokenIds[1], defaultCollateral, expectedDebt, defaultInterestRate);

    //     // // Fast forward 6 months
    //     // vm.warp(vm.getBlockTimestamp() + (365 days / 4));

    //     // confirm open fees are equal
    //     (, int256 debtDiff1,,) = nectra.quoteModifyPosition(tokenIds[1], 0, 0, defaultInterestRate);
    //     (, int256 debtDiff2,,) = nectra.quoteModifyPosition(tokenIds[1], 0, 0, defaultInterestRate);
    //     assertEq(debtDiff1, debtDiff2, "Open fees are not equal");
    // }

    // Redeemed collateral socialization
    function test_should_not_socialize_redeemed_collateral_to_new_position_in_same_bucket() public {
        // increase redemption accumulator for 0.5% bucket
        _createAndFullyRedeemPosition();

        // create new position in 0.5% bucket with default position size
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm accumulated redeemed collateral is not socialized to new position
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);
    }

    function test_should_not_socialize_redeemed_collateral_to_new_position_in_new_bucket() public {
        // accumulate liquidation collateral and debt in 5% bucket
        _createAndFullyRedeemPosition();

        uint256 interestRate = 0.1 ether;
        // create new position in 5% bucket with default position
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), interestRate, ""
        );

        // confirm accumulated redeemed collateral is not socialized to new position
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, interestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_closing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        uint256 collateralBalanceBefore = address(this).balance;
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));

        // close position
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(tokenId, -int256(collateral), -int256(debt), cargs.minimumInterestRate, "");

        // confirm position is correct after closing
        _checkPosition(tokenId, 0, 0, cargs.minimumInterestRate);

        // confirm transfer amounts are correct
        assertApproxEqRel(
            address(this).balance - collateralBalanceBefore, collateral, 1e11, "Incorrect collateral received"
        );
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)), debt, "Incorrect debt paid");
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_repaying() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        // repay debt
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(tokenId, 0, -1 ether, cargs.minimumInterestRate, "");

        // confirm position is correct after repaying
        _checkPosition(tokenId, collateral, debt - UNIT, cargs.minimumInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_borrowing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        // borrow debt
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition(tokenId, 0, 1 ether, cargs.minimumInterestRate, "");

        // Note:when borrowing the outstanding fee is increased by
        // the change amount multiplied by the open fee percentage
        uint256 newFee = UNIT * cargs.openFeePercentage / UNIT;
        _checkPosition(tokenId, collateral, debt + UNIT + newFee, cargs.minimumInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_depositing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        // deposit collateral
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition{value: 1 ether}(tokenId, 1 ether, 0, cargs.minimumInterestRate, "");

        // confirm position is correct after depositing
        _checkPosition(tokenId, collateral + UNIT, debt, cargs.minimumInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_withdrawing() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        // withdraw collateral
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        nectra.modifyPosition(tokenId, -1 ether, 0, cargs.minimumInterestRate, "");

        // confirm position is correct after withdrawing
        _checkPosition(tokenId, collateral - UNIT, debt, cargs.minimumInterestRate);
    }

    function test_should_socialize_redeemed_collateral_to_existing_position_before_increasing_interest_rate() public {
        // create position in 0.5% bucket before redemption
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), cargs.minimumInterestRate, ""
        );

        // confirm position is correct before redemption
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);

        uint256 bucketDebtBeforeRedemption = nectraExternal.getBucketDebt(cargs.minimumInterestRate);
        uint256 positionDebtBeforeRedemption =
            nectraExternal.getPositionDebt(tokenId) - nectraExternal.getPositionOutstandingFee(tokenId);

        // increase redemption accumulator for 0.5% bucket
        (uint256 redeemedCollateral, uint256 redeemedDebt) = _createAndFullyRedeemPosition();

        uint256 factor = positionDebtBeforeRedemption * UNIT / (bucketDebtBeforeRedemption + redeemedDebt);
        uint256 collateralAfterRedemption = defaultCollateral - redeemedCollateral * factor / UNIT;
        uint256 debtAfterRedemption = defaultDebt + closingFee - redeemedDebt * factor / UNIT;

        // confirm position is correct before modification
        _checkPosition(tokenId, collateralAfterRedemption, debtAfterRedemption, cargs.minimumInterestRate);

        // increase interest rate
        nectra.modifyPosition(tokenId, 0, 0, cargs.minimumInterestRate + cargs.interestRateIncrement, "");

        // confirm position is correct after increasing interest rate
        _checkPosition(
            tokenId,
            collateralAfterRedemption,
            debtAfterRedemption,
            cargs.minimumInterestRate + cargs.interestRateIncrement
        );
    }

    function test_migrating_to_a_bucket_with_a_new_epoch_should_work() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0,
            int256(defaultCollateral),
            int256(defaultDebt),
            cargs.minimumInterestRate + cargs.interestRateIncrement,
            ""
        );

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);

        // fully redeem the first bucket
        _createAndFullyRedeemPosition();

        // migrate position to new epoch
        nectra.modifyPosition(tokenId, 0, 0, cargs.minimumInterestRate, "");

        // confirm position is correct after migration
        _checkPosition(tokenId, defaultCollateral, defaultDebt + closingFee, cargs.minimumInterestRate);
    }

    // withdraw should be reentrant safe
    function test_should_be_reentrant_safe() public {
        // create position
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: defaultCollateral}(
            0, int256(defaultCollateral), int256(defaultDebt), defaultInterestRate, ""
        );

        // confirm position is correct
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        uint256 totalDebt = defaultDebt + closingFee;
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
        nectra.modifyPosition(
            defaultTokenId, int256(defaultCollateral), int256(defaultDebt + 1), defaultInterestRate, ""
        );
    }

    function test_should_fail_when_withdrawing_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to decrease collateral
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(
            defaultTokenId, int256(defaultCollateral - 1), int256(defaultDebt), defaultInterestRate, ""
        );
    }

    function test_should_fail_when_changing_interest_rate_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to increase interest rate
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(
            defaultTokenId,
            int256(defaultCollateral),
            int256(defaultDebt),
            defaultInterestRate + cargs.interestRateIncrement,
            ""
        );

        // position owner try to decrease interest rate
        vm.expectRevert(INectra.InvalidCollateralPrice.selector);
        nectra.modifyPosition(
            defaultTokenId,
            int256(defaultCollateral),
            int256(defaultDebt),
            defaultInterestRate - cargs.interestRateIncrement,
            ""
        );
    }

    function test_should_allow_repaying_with_stale_oracle() public {
        oracle.setStale(true);

        // get closing fee before change to calculate full charge
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        // position owner try to repay debt
        nectraUSD.approve(address(nectra), UNIT);
        nectra.modifyPosition(defaultTokenId, 0, -1 ether, defaultInterestRate, "");

        _checkPosition(defaultTokenId, defaultCollateral, defaultDebt - UNIT + closingFee, defaultInterestRate);
    }

    function test_should_allow_depositing_with_stale_oracle() public {
        oracle.setStale(true);

        // position owner try to deposit collateral
        nectra.modifyPosition{value: 1 ether}(defaultTokenId, 1 ether, 0, defaultInterestRate, "");

        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);
        _checkPosition(defaultTokenId, defaultCollateral + 1 ether, defaultDebt + closingFee, defaultInterestRate);
    }

    function test_should_allow_closing_with_stale_oracle() public {
        oracle.setStale(true);
        uint256 collateralBalanceBefore = address(this).balance;
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(defaultTokenId);
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(defaultTokenId);

        // position owner try to close position
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(defaultTokenId, -int256(collateral), -int256(debt), defaultInterestRate, "");

        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm transfer amounts are correct
        assertEq(address(this).balance - collateralBalanceBefore, collateral, "Incorrect collateral received");
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)) - closingFee, debt, "Incorrect debt paid");
    }

    // Amount caps
    function test_should_cap_withdrawal_amount_at_available_collateral() public {
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(defaultTokenId);
        uint256 collateralBalanceBefore = address(this).balance;

        // close position but withdraw more collateral than what is available
        deal(address(nectraUSD), address(this), debt);
        nectraUSD.approve(address(nectra), debt);
        nectra.modifyPosition(defaultTokenId, -int256(collateral + 10 ether), -int256(debt), defaultInterestRate, "");

        // confirm position is correct
        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm collateral is correct
        assertEq(address(this).balance - collateralBalanceBefore, collateral, "Incorrect collateral received");
    }

    function test_should_cap_repayment_amount_at_available_debt() public {
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(defaultTokenId);

        deal(address(nectraUSD), address(this), debt * 2);
        uint256 nUSDBalanceBefore = nectraUSD.balanceOf(address(this));

        // close position but repay more debt than what is available
        nectraUSD.approve(address(nectra), debt * 2);
        nectra.modifyPosition(defaultTokenId, -int256(collateral), -int256(debt * 2), defaultInterestRate, "");

        // confirm position is correct
        _checkPosition(defaultTokenId, 0, 0, defaultInterestRate);

        // confirm collateral is correct
        assertEq(nUSDBalanceBefore - nectraUSD.balanceOf(address(this)), debt, "Incorrect debt paid");
    }

    function _createAndForceLiquidatePosition() internal {
        (uint256 initialPrice,) = oracle.getLatestPrice();
        uint256 collateralAmount = 1000 ether;
        uint256 debtAtIssuance =
            collateralAmount * initialPrice / (cargs.issuanceRatio * (UNIT + cargs.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: collateralAmount}(
            0, int256(collateralAmount), int256(debtAtIssuance), cargs.minimumInterestRate, ""
        );

        // move price to force liquidation price
        uint256 forceLiquidationPrice = debtAtIssuance * cargs.fullLiquidationRatio / collateralAmount;
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
        socializedDebt =
            socializedCollateral * initialPrice / (cargs.issuanceRatio * (UNIT + cargs.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: socializedCollateral}(
            0, int256(socializedCollateral), int256(socializedDebt), interestRate, ""
        );
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);

        // move price to force liquidation price
        uint256 forceLiquidationPrice = socializedDebt * cargs.fullLiquidationRatio / socializedCollateral;
        oracle.setCurrentPrice(forceLiquidationPrice);

        // liquidate position
        nectra.fullLiquidate(tokenId);

        // return price to initial price
        oracle.setCurrentPrice(initialPrice);

        // increase socialized debt by closing fee and full liquidation fee that were also socialized
        socializedDebt += closingFee + cargs.fullLiquidationFee;
    }

    function _createAndForceLiquidatePositionInBucketWithCollateral(uint256 interestRate, uint256 collateralAmount)
        internal
    {
        (uint256 initialPrice,) = oracle.getLatestPrice();
        uint256 debtAtIssuance =
            collateralAmount * initialPrice / (cargs.issuanceRatio * (UNIT + cargs.openFeePercentage) / UNIT);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: collateralAmount}(
            0, int256(collateralAmount), int256(debtAtIssuance), interestRate, ""
        );
        // move price to force liquidation price
        uint256 forceLiquidationPrice = debtAtIssuance * cargs.fullLiquidationRatio / collateralAmount;
        oracle.setCurrentPrice(forceLiquidationPrice);

        // liquidate position
        nectra.fullLiquidate(tokenId);

        // return price to initial price
        oracle.setCurrentPrice(initialPrice);
    }

    function _createAndFullyRedeemPosition() internal returns (uint256 redeemedCollateral, uint256 redeemedDebt) {
        uint256 collateral = 1000 ether;
        redeemedDebt = 500 ether;
        nectra.modifyPosition{value: collateral}(
            0, int256(collateral), int256(redeemedDebt), cargs.minimumInterestRate, ""
        );

        // calculate redeemed collateral
        (uint256 price,) = oracle.getLatestPrice();
        redeemedCollateral = redeemedDebt * UNIT / price;
        // redemption fee rounds up by 1 wei
        uint256 redemptionFeePercentage = nectra.getRedemptionFee(redeemedDebt) + 1;
        uint256 redemptionTreasuryFeePercentage = 0;

        // split fee between treasury and positions
        if (redemptionFeePercentage > cargs.redemptionFeeTreasuryThreshold) {
            redemptionTreasuryFeePercentage = redemptionFeePercentage - cargs.redemptionFeeTreasuryThreshold;
            redemptionFeePercentage = cargs.redemptionFeeTreasuryThreshold;
        }

        // the amount redeemed from the positions is the total less the treasury split
        redeemedCollateral -= redeemedCollateral * redemptionFeePercentage / UNIT;

        // redeem position with slippage protection
        nectraUSD.approve(address(nectra), redeemedDebt);
        // minAmountOut should deduct the entire redemption fee
        nectra.redeem(redeemedDebt, redeemedCollateral - redeemedCollateral * redemptionFeePercentage / UNIT);
    }
}
