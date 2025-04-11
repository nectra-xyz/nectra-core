// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraLiquidate} from "src/NectraLiquidate.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";
import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {IERC20} from "src/interfaces/IERC20.sol";

import {DEXMock} from "test/mocks/DEXMock.sol";

contract NectraLiquidatePartialTest is NectraBaseTest {
    using FixedPointMathLib for uint256;

    struct PartialLiquidationAmounts {
        uint256 initialCollateral;
        uint256 initialDebt;
        uint256 closingFee;
        uint256 liquidationPrice;
        uint256 amountToFix;
        uint256 debtToLiquidate;
        uint256 collateralToLiquidate;
        uint256 penalty;
        uint256 penaltyCollateral;
        uint256 amountToFeeRecipient;
        uint256 amountToLiquidator;
    }

    DEXMock internal mockDex;

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
            0, int256(defaultCollateral), int256(20 ether), defaultInterestRate, ""
        );
        tokens.push(tokenId);

        mockDex = new DEXMock(address(nectraUSD), address(nectra), address(oracle));
        // Give mock DEX some cBTC to trade
        deal(address(mockDex), 10_000_000 ether);
    }

    // Flash borrow should be locked
    function test_should_revert_when_called_with_flash_borrow() public {
        vm.expectRevert(abi.encodeWithSelector(NectraBase.FlashBorrowInProgress.selector));
        nectra.flashBorrow(address(this), 100 ether, "");
    }

    // Flash mint should be allowed
    function test_should_allow_flash_mint() public {
        return;
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);

        // test with 0.01% slippage and fees
        mockDex.setSlippageAndFees(0.0001 ether);

        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);
        nectra.flashMint(address(this), liquidationAmounts.debtToLiquidate, "");

        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );
    }

    // Revert permutations
    function test_should_revert_for_invalid_position_id() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForLiquidation.selector, type(uint256).max, cargs.liquidationRatio
            )
        );
        nectra.liquidate(31337);
    }

    function test_should_revert_when_oracle_price_is_stale() public {
        oracle.setStale(true);

        vm.expectRevert(abi.encodeWithSelector(NectraBase.InvalidCollateralPrice.selector));
        nectra.liquidate(tokens[1]);
    }

    function test_should_revert_for_position_not_eligible_for_partial_liquidation() public {
        uint256 tokenId = tokens[1];

        vm.expectRevert(
            abi.encodeWithSelector(
                NectraLiquidate.NotEligibleForLiquidation.selector, 1411764705882352941, cargs.liquidationRatio
            )
        );
        nectra.liquidate(tokenId);

        assertEq(nectraExternal.canLiquidate(tokenId), false, "Position should not be eligible for partial liquidation");
    }

    function test_should_revert_when_insufficient_allowance() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);

        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        // zero allowance
        vm.expectRevert(abi.encodeWithSelector(IERC20.InsufficientAllowance.selector));
        nectra.liquidate(tokenId);

        // non-zero allowance
        nectraUSD.approve(address(nectra), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20.InsufficientAllowance.selector));
        nectra.liquidate(tokenId);

        // 1 wei short of required allowance
        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate - 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20.InsufficientAllowance.selector));
        nectra.liquidate(tokenId);
    }

    function test_should_revert_when_partial_liquidation_would_leave_position_insolvent() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, 0.82 ether);

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);

        vm.expectRevert(abi.encodeWithSelector(NectraBase.InsufficientCollateral.selector));
        nectra.liquidate(tokenId);
    }

    function test_should_allow_partial_liquidation_when_position_cratio_equals_liquidation_ratio() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);

        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );
    }

    function test_should_burn_nusd_during_partial_liquidation() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);
        uint256 nUSDBefore = nectraUSD.balanceOf(address(this));
        uint256 nUSDTotalSupplyBefore = nectraUSD.totalSupply();

        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        assertEq(
            nectraUSD.balanceOf(address(this)),
            nUSDBefore - liquidationAmounts.debtToLiquidate,
            "nUSD not burned correctly"
        );
        assertEq(
            nectraUSD.totalSupply(),
            nUSDTotalSupplyBefore - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee,
            "nUSD total supply not updated correctly"
        );
    }

    function test_should_realise_oustanding_interest_before_partial_liquidation() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        //uint256 closingFee = nectra.getClosingFee(tokenId, debt);
        (uint256 collateralPrice,) = oracle.getLatestPrice();
        // calculate the time shift required to make the position eligible for full liquidation due to interest
        uint256 targetInterest = collateral.mulWad(collateralPrice).divWad(cargs.liquidationRatio) - debt;
        uint256 timeShift = targetInterest.divWad(defaultInterestRate.mulWad(debt));
        uint256 targetTime = vm.getBlockTimestamp() + (timeShift * 365 days / UNIT);

        // confirm position is not liquidatable because interest is not accrued
        assertEq(nectraExternal.canLiquidate(tokenId), false, "Position should not be eligible for partial liquidation");

        vm.warp(targetTime);

        // confirm position is liquidatable because interest is accrued
        assertEq(nectraExternal.canLiquidate(tokenId), true, "Position should be eligible for partial liquidation");

        // confirm can liquidate but dont check balances here
        nectraUSD.approve(address(nectra), type(uint256).max);
        nectra.liquidate(tokenId);
    }

    function test_should_realise_oustanding_fees_before_partial_liquidation() public {
        uint256 tokenId = tokens[1];
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        //uint256 closingFee = nectra.getClosingFee(tokenId, debt);

        // Move position cratio to exactly the partial liquidation ratio
        // with the closing fee realized. If the closing fee is > 0 and
        // is not considered, the position will not be eligible for partial liquidation
        // when liquidate is called.
        uint256 priceBeforePartialLiquidaition = cargs.liquidationRatio * debt / collateral;

        // confirm position is not liquidatable because fees are not enough
        assertEq(nectraExternal.canLiquidate(tokenId), false, "Position should not be eligible for partial liquidation");

        // change the price to push position into liquidation due to realized fees
        oracle.setCurrentPrice(priceBeforePartialLiquidaition);

        // confirm position is liquidatable because collateral value is bad enough that fees push it over
        assertEq(nectraExternal.canLiquidate(tokenId), true, "Position should be eligible for partial liquidation");

        // confirm can liquidate but dont check balances here
        nectraUSD.approve(address(nectra), type(uint256).max);
        nectra.liquidate(tokenId);
    }

    function test_should_allow_partial_liquidation_when_position_cratio_is_below_liquidation_ratio() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, 0.9 ether);

        // confirm position is not liquidatable because collateral value is not bad enough
        assertEq(nectraExternal.canLiquidate(tokenId), false, "Position should not be eligible for partial liquidation");

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        // check that position is at issuance ratio, don't need to consider closing fee because it is paid
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        uint256 cratio = collateral.mulWad(liquidationAmounts.liquidationPrice).divWad(debt);
        // Within 1 wei of eachother because of 1 wei rounding
        assertApproxEqRel(cratio, cargs.issuanceRatio, 1, "Position is not at issuance ratio");
    }

    function test_should_pay_liquidator_reward() public {
        uint256 tokenId = tokens[1];
        address liquidator = makeAddr("liquidator");
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);

        nectraUSD.transfer(liquidator, liquidationAmounts.debtToLiquidate);

        // check balances before liquidation
        uint256 liquidatorcBTCBalanceBefore = liquidator.balance;
        uint256 feeRecipientcBTCBalanceBefore = address(feeRecipient).balance;
        uint256 liquidatornUSDBalanceBefore = nectraUSD.balanceOf(liquidator);
        uint256 nectracBTCBalanceBefore = address(nectra).balance;

        // change the price to make position cratio equals the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        vm.startPrank(liquidator);
        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);
        vm.stopPrank();

        // check that the position is partially liquidated and that correct amount of collateral redeemed and debt is paid
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        // check liquidator balances
        assertEq(
            liquidator.balance,
            liquidatorcBTCBalanceBefore + liquidationAmounts.amountToLiquidator,
            "Liquidator cBTC balance not updated correctly"
        );
        assertEq(
            nectraUSD.balanceOf(liquidator),
            liquidatornUSDBalanceBefore - liquidationAmounts.debtToLiquidate,
            "Liquidator nUSD balance not updated correctly"
        );
        // check liquidation is profitable
        assertGt(
            liquidationAmounts.amountToLiquidator.mulWad(liquidationAmounts.liquidationPrice),
            liquidationAmounts.debtToLiquidate,
            "Insufficient collateral reward paid to liquidator"
        );

        // check fee recipient balances
        assertEq(
            address(feeRecipient).balance,
            feeRecipientcBTCBalanceBefore + liquidationAmounts.amountToFeeRecipient,
            "Fee recipient cBTC balance not updated correctly"
        );

        // confirm collateral has left nectra
        assertEq(
            address(nectra).balance,
            nectracBTCBalanceBefore - liquidationAmounts.collateralToLiquidate,
            "Collateral not removed from nectra"
        );
    }

    function test_should_update_bucket_and_global_state_correctly() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);
        (
            NectraLib.PositionState memory positionBefore,
            NectraLib.BucketState memory bucketBefore,
            NectraLib.GlobalState memory globalStateBefore
        ) = nectra.getPositionState(tokenId);
        uint256 bucketDebtBefore = nectraExternal.getBucketDebt(defaultInterestRate);
        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        // check that position is correctly removed from bucket and global state
        uint256 bucketDebtAfter = nectraExternal.getBucketDebt(defaultInterestRate);
        (
            NectraLib.PositionState memory positionAfter,
            NectraLib.BucketState memory bucketAfter,
            NectraLib.GlobalState memory globalStateAfter
        ) = nectra.getPositionState(tokenId);

        uint256 expectedGlobalDebt =
            globalStateBefore.debt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        uint256 expectedBucketDebt =
            bucketDebtBefore - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        uint256 expectedCollateralPerShare = globalStateBefore.accumulatedLiquidatedCollateralPerShare;
        uint256 expectedDebtPerShare = globalStateBefore.accumulatedLiquidatedDebtPerShare;

        assertEq(globalStateAfter.debt, expectedGlobalDebt, "global debt not deducted correctly");
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

        // check postion debt shares are updated correctly
        uint256 positionDebtShareDecrease = (liquidationAmounts.debtToLiquidate - liquidationAmounts.closingFee).mulWad(
            bucketBefore.totalDebtShares
        ).divWad(bucketDebtBefore);
        assertEq(
            positionAfter.debtShares,
            positionBefore.debtShares - positionDebtShareDecrease,
            "position debt shares not updated correctly"
        );
        assertEq(
            bucketAfter.totalDebtShares,
            bucketBefore.totalDebtShares - positionDebtShareDecrease,
            "bucket total debt shares not updated correctly"
        );
        // check that bucket debt shares are updated correctly
        uint256 bucketDebtShareDecrease = (liquidationAmounts.debtToLiquidate - liquidationAmounts.closingFee).mulWad(
            globalStateBefore.totalDebtShares
        ).divWad(globalStateBefore.debt);
        assertEq(
            bucketAfter.globalDebtShares,
            bucketBefore.globalDebtShares - bucketDebtShareDecrease,
            "bucket debt shares not updated correctly"
        );
        assertEq(
            globalStateAfter.totalDebtShares,
            globalStateBefore.totalDebtShares - bucketDebtShareDecrease,
            "global total debt shares not updated correctly"
        );

        // check that bucket and global state are updated correctly when updatePosition is called
        nectra.updatePosition(tokenId);

        (NectraLib.BucketState memory bucketAfterUpdate, NectraLib.GlobalState memory globalStateAfterUpdate) =
            nectra.getBucketState(defaultInterestRate);
        uint256 bucketDebtAfterUpdate = nectraExternal.getBucketDebt(defaultInterestRate);

        assertEq(globalStateAfterUpdate.debt, expectedGlobalDebt, "global debt not updated correctly");
        assertEq(bucketDebtAfterUpdate, expectedBucketDebt, "bucket debt not updated correctly");
    }

    function test_should_cap_liquidator_reward() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);
        uint256 cBTCBalanceBefore = address(this).balance;

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt + liquidationAmounts.closingFee - liquidationAmounts.debtToLiquidate;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        // check that liquidator reward is capped at maximum liquidator reward
        uint256 cBTCReceived = address(this).balance - cBTCBalanceBefore;
        uint256 rewardAmount =
            cBTCReceived.mulWad(liquidationAmounts.liquidationPrice) - liquidationAmounts.debtToLiquidate;
        console2.log("reward amount ", rewardAmount);
        assertLt(
            rewardAmount, cargs.maximumLiquidatorReward, "Liquidator reward is not capped at maximum liquidator reward"
        );
    }

    function test_lowest_cratio_that_is_still_profitable_for_liquidator() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts =
            _calculatePartialLiquidationAmounts(tokenId, 0.85453 ether);
        uint256 cBTCBalanceBefore = address(this).balance;

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        uint256 cratio = liquidationAmounts.initialCollateral.mulWad(liquidationAmounts.liquidationPrice).divWad(
            liquidationAmounts.initialDebt + liquidationAmounts.closingFee
        );
        console2.log("cratio ", cratio);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt + liquidationAmounts.closingFee - liquidationAmounts.debtToLiquidate;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        // check that liquidator reward is capped at maximum liquidator reward
        uint256 cBTCReceived = address(this).balance - cBTCBalanceBefore;
        uint256 rewardAmount =
            cBTCReceived.mulWad(liquidationAmounts.liquidationPrice) - liquidationAmounts.debtToLiquidate;
        assertLt(
            rewardAmount, cargs.maximumLiquidatorReward, "Liquidator reward is not capped at maximum liquidator reward"
        );
    }

    function test_should_not_be_profitable_to_liquidate_self() public {
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);
        uint256 cbtcBalanceBefore = address(this).balance;
        uint256 feeRecipientcBTCBalanceBefore = address(feeRecipient).balance;

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        nectraUSD.approve(address(nectra), liquidationAmounts.debtToLiquidate);
        nectra.liquidate(tokenId);

        // check that the position is partially liquidated
        uint256 expectedDebt =
            liquidationAmounts.initialDebt - liquidationAmounts.debtToLiquidate + liquidationAmounts.closingFee;
        _checkPosition(
            tokenId,
            liquidationAmounts.initialCollateral - liquidationAmounts.collateralToLiquidate,
            expectedDebt,
            defaultInterestRate
        );

        uint256 cbtcReceived = address(this).balance - cbtcBalanceBefore;
        uint256 feeRecipientcBTCReceived = address(feeRecipient).balance - feeRecipientcBTCBalanceBefore;

        // check that self liquidation is not profitable
        assertTrue(
            feeRecipientcBTCReceived
                >= cbtcReceived - liquidationAmounts.debtToLiquidate.divWad(liquidationAmounts.liquidationPrice),
            "Self liquidation is profitable"
        );
    }

    function test_should_allow_repay_when_position_is_liquidatable() public {
        return;
        uint256 tokenId = tokens[1];
        PartialLiquidationAmounts memory liquidationAmounts = _calculatePartialLiquidationAmounts(tokenId, UNIT);
        uint256 nUSDBefore = nectraUSD.balanceOf(address(this));

        // change the price to make position cratio less than the liquidation ratio
        oracle.setCurrentPrice(liquidationAmounts.liquidationPrice);

        assertEq(nectraExternal.canLiquidate(tokenId), true, "Position should be liquidatable");

        // approve and repay debt to leave position in healthy state
        nectraUSD.approve(address(nectra), type(uint256).max);

        uint256 newDebt = liquidationAmounts.initialDebt - 15 ether;
        uint256 closingFee = nectraExternal.getPositionOutstandingFee(tokenId);
        // TODO: just making these ints so that it will compile, the values will need to be deltas and not absolute values
        nectra.modifyPosition(
            tokenId, int256(liquidationAmounts.initialCollateral), int256(newDebt), defaultInterestRate, ""
        );

        // check that position is in healthy state
        // NectraLib.PositionState memory positionState = nectra.getPositionState(tokenId);
        (uint256 collateral, uint256 debt) = nectraExternal.getPosition(tokenId);
        assertGt(
            collateral.mulWad(liquidationAmounts.liquidationPrice).divWad(debt),
            cargs.issuanceRatio,
            "Position is not in healthy state"
        );
        assertEq(nectraUSD.balanceOf(address(this)), nUSDBefore - 15 ether - closingFee, "nUSD not burned correctly");
        _checkPosition(tokenId, liquidationAmounts.initialCollateral, newDebt, defaultInterestRate);
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

        uint256 cbtcBalanceBefore = address(this).balance;
        nectraUSD.approve(address(nectra), amount);
        nectra.liquidate(tokens[1]);

        uint256 cbtcReceived = address(this).balance - cbtcBalanceBefore;

        // Swap cBTC for nUSD with DEXMock
        uint256 nUSDAmount = mockDex.sellBTC{value: cbtcReceived}(cbtcReceived);

        // TODO: figure out what to do with the profitability check. Right now it is not because of gas and swap fees
        /*
        * test_should_allow_flash_mint() (gas: 467675)
        * Assuming gas prices are around 40x cheaper than ETH based L2s
        * because the network token is around 40x more expensive than ETH
        * 
        * Cost = 467,675 × 0.0125 gwei = 5,845.9375 gwei
        * In network token terms = 0.0000058459375 tokens
        * In USD terms = 0.0000058459375 × $100,000 ≈ $0.58
        */
        (uint256 price,) = oracle.getLatestPrice();
        uint256 gasCost = 5845937500000 * price / 1 ether;

        assertGt(nUSDAmount, amount + premium + gasCost, "Not enough nUSD received");

        // Repay the flash loan -- assume enough assets are in the contract
        if (asset == address(nectraUSD)) {
            nectraUSD.approve(msg.sender, amount + premium);
        } else {
            nectra.repayFlashBorrow{value: amount + premium}();
        }

        return true;
    }

    function _calculatePartialLiquidationAmounts(uint256 tokenId, uint256 priceScale)
        internal
        view
        returns (PartialLiquidationAmounts memory liquidationAmounts)
    {
        // NectraLib.PositionState memory positionState = nectra.getPositionState(tokenId);
        (liquidationAmounts.initialCollateral, liquidationAmounts.initialDebt) = nectraExternal.getPosition(tokenId);
        liquidationAmounts.closingFee = nectraExternal.getPositionOutstandingFee(tokenId);

        liquidationAmounts.liquidationPrice = nectraExternal.getPositionLiquidationPrice(tokenId);
        liquidationAmounts.liquidationPrice = liquidationAmounts.liquidationPrice.mulWad(priceScale);

        // calculate amount to fix the position
        // uint256 amountToFix = (
        //     liquidationAmounts.initialDebt.mulWadUp(ISSUANCE_RATIO) - liquidationAmounts.initialCollateral.mulWad(globalState.collateralPrice)
        // ).divWadUp(ISSUANCE_RATIO - 1 ether);
        uint256 numerator = liquidationAmounts.initialDebt.mulWadUp(cargs.issuanceRatio)
            - liquidationAmounts.initialCollateral.mulWadUp(liquidationAmounts.liquidationPrice);
        liquidationAmounts.amountToFix = numerator.divWadUp(cargs.issuanceRatio - UNIT);

        // calculate the amount of collateral to redeem
        // uint256 collateralToRedeem = amountToFix.divWadUp(globalState.collateralPrice);
        liquidationAmounts.collateralToLiquidate =
            liquidationAmounts.amountToFix.divWadUp(liquidationAmounts.liquidationPrice);
        // uint256 penalty = amountToFix.mulWadUp(LIQUIDATION_PENALTY_PERCENTAGE);
        liquidationAmounts.penalty = liquidationAmounts.amountToFix.mulWadUp(cargs.liquidationPenaltyPercentage);
        // uint256 penaltyCollateral = penalty.divWadUp(globalState.collateralPrice).mulWadUp(ISSUANCE_RATIO);
        liquidationAmounts.penaltyCollateral =
            liquidationAmounts.penalty.divWadUp(liquidationAmounts.liquidationPrice).mulWadUp(cargs.issuanceRatio);

        // calculate the amount of collateral to redeem
        // uint256 collateralToRedeem = amountToFix.divWadUp(globalState.collateralPrice);
        uint256 collateralToRedeem = liquidationAmounts.amountToFix.divWadUp(liquidationAmounts.liquidationPrice);
        liquidationAmounts.collateralToLiquidate = collateralToRedeem + liquidationAmounts.penaltyCollateral;
        liquidationAmounts.debtToLiquidate = liquidationAmounts.amountToFix + liquidationAmounts.penalty;

        // calculate liquidator reward, capped to max liquidator reward
        liquidationAmounts.amountToLiquidator =
            liquidationAmounts.penaltyCollateral.mulWad(cargs.liquidatorRewardPercentage);
        uint256 maxLiquidatorReward = cargs.maximumLiquidatorReward.divWad(liquidationAmounts.liquidationPrice);
        if (liquidationAmounts.amountToLiquidator > maxLiquidatorReward) {
            liquidationAmounts.amountToLiquidator = maxLiquidatorReward;
        }

        // calculate the amount of collateral to send to the fee recipient
        liquidationAmounts.amountToFeeRecipient =
            liquidationAmounts.penaltyCollateral - liquidationAmounts.amountToLiquidator;
        // add the collateral to redeem to the liquidator reward
        liquidationAmounts.amountToLiquidator += collateralToRedeem;
    }
}
