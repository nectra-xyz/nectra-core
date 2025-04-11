// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraRedeemBaseTest, console2} from "test/redeem/NectraRedeemBase.t.sol";
import {NectraLib} from "src/NectraLib.sol";

contract NectraRedeemWithoutFeesTest is NectraRedeemBaseTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_redeem_iterates_buckets() public {
        // first redemption reduces debt of positions [0,1]
        {
            _validatePositions();
            _redeemAndValidate(5 ether, 4.166666666666667 ether, 0); // 5 / 1.2

            // (100 - 5 / 1.2 * 10 / (10 + 35)); (10 - 5 * 10 / (10 + 35))
            (collateral[0], debt[0]) = (99.07407407 ether, 8.888888889 ether);

            // (100 - 5 / 1.2 * 35 / (10 + 35)); (35 - 5 * 35 / (10 + 35))
            (collateral[1], debt[1]) = (96.75925926 ether, 31.11111111 ether);

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 40 ether, "incorrect bucket debt");

            _validatePositions();
        }

        // second redemption clears the 5% bucket and positions [0,1]
        // and the leaves 5.01% bucket and position [2] with $ 1 of debt
        // the 5.01% is one interest interval above the 5% bucket (adjacent)
        {
            _redeemAndValidate(41 ether, 34.16666666666667 ether, 0);

            // (C0 - 40 / 1.2 * D0 / (D0 + D1)); 0
            (collateral[0], debt[0]) = (91.66666667 ether, 0 ether);

            // (C1 - 40 / 1.2 * D1 / (D0 + D1)); 0
            (collateral[1], debt[1]) = (70.83333333 ether, 0 ether);

            // (C2 - 1 / 1.2); (D2 - 1)
            (collateral[2], debt[2]) = (99.16666667 ether, 4 ether);

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.051 ether), 4 ether, "incorrect bucket debt");

            _validatePositions();
        }

        // third redemption clears the 5.01% bucket and position [2]
        // and the leaves 10% bucket (positions [3,4]) with $ 35 of debt
        {
            _redeemAndValidate(14 ether, 11.66666666666666 ether, 0);

            // (C2  - 4 / 1.2); (D2 - 4)
            (collateral[2], debt[2]) = (95.83333333 ether, 0 ether);

            // (C3 - 1 / 1.2 * D3 / (D3 + D4)); (D3 - 1 * D3 / (D3 + D4))
            (collateral[3], debt[3]) = (96.2962963 ether, 15.55555556 ether);

            // (C4 - 1 / 1.2 * D4 / (D3 + D4)); (D4 - 1 * D4 / (D3 + D4))
            (collateral[4], debt[4]) = (95.37037037 ether, 19.44444444 ether);

            assertEq(nectraExternal.getBucketDebt(0.05 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.051 ether), 0 ether, "incorrect bucket debt");
            assertEq(nectraExternal.getBucketDebt(0.1 ether), 35 ether, "incorrect bucket debt");

            _validatePositions();
        }
    }

    function test_redeem_readd_bucket() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        nectra.redeem(60 ether, 0 ether);

        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1e11);

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 10 ether, 0.05 ether, "");

        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 10 ether, 1e11);
        assertApproxEqRel(nectraExternal.getBucketDebt(0.05 ether), 10 ether, 1e11);

        nectra.redeem(10 ether, 0 ether);

        assertApproxEqAbs(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1);
        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 0 ether, 1e11);
    }

    function test_redeem_withdraw_collateral() public {
        nectra.redeem(65 ether, 0 ether);

        assertApproxEqAbs(nectraExternal.getBucketDebt(0.05 ether), 0 ether, 1);

        (, int256 _collateral, int256 _debt,,) =
            nectra.modifyPosition(tokens[1], type(int256).min, type(int256).min, 0.05 ether, "");

        assertApproxEqRel(_collateral, -70.833333333333333 ether, 1e11); // 100 - 35 / 1.2
        assertApproxEqAbs(_debt, 0 ether, 1);
    }

    function test_redeem_100_percent_debt_and_claim_remaining_collateral() public {
        deal(address(nectraUSD), address(this), 10000 ether);
        // Calculate total debt across all positions
        uint256 totalDebt = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            (, uint256 positionDebt) = nectraExternal.getPosition(tokens[i]);
            totalDebt += positionDebt;
        }

        // Record initial balances
        uint256 initialNUSDBalance = nectraUSD.balanceOf(address(this));
        uint256 initialETHBalance = address(this).balance;
        uint256[] memory initialCollateral = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (initialCollateral[i],) = nectraExternal.getPosition(tokens[i]);
        }

        // Approve and redeem full amount
        nectraUSD.approve(address(nectra), type(uint256).max);
        uint256 collateralRedeemed = nectra.redeem(totalDebt - 1 wei, 0);

        // Verify all positions have 0 debt after redemption
        for (uint256 i = 0; i < tokens.length - 2; i++) {
            (, uint256 finalDebt) = nectraExternal.getPosition(tokens[i]);
            assertEq(finalDebt, 0, "Position should have 0 debt after redemption");
        }

        // Verify all bucket debts are 0
        assertEq(nectraExternal.getBucketDebt(0.05 ether), 0, "5% bucket should be empty");
        assertEq(nectraExternal.getBucketDebt(0.1 ether), 0, "10% bucket should be empty");
        assertEq(nectraExternal.getBucketDebt(0.2 ether), 1, "20% bucket should be empty minus rounding");

        // Verify nUSD was burned
        uint256 finalNUSDBalance = nectraUSD.balanceOf(address(this));
        assertApproxEqRel(initialNUSDBalance - finalNUSDBalance, totalDebt, 1e11, "Incorrect amount of nUSD burned");

        // Verify collateral was redeemed
        uint256 finalETHBalance = address(this).balance;
        assertEq(finalETHBalance, initialETHBalance + collateralRedeemed, "Should receive collateral from redemption");

        // Verify position owners can still claim remaining collateral
        for (uint256 i = 0; i < tokens.length - 2; i++) {
            uint256 balanceBeforeClaim = address(this).balance;
            (uint256 currentCollateral, uint256 currentDebt) = nectraExternal.getPosition(tokens[i]);

            // Claim remaining collateral
            nectra.modifyPosition(tokens[i], type(int256).min, type(int256).min, interestRates[i], "");

            uint256 balanceAfterClaim = address(this).balance;
            uint256 collateralClaimed = balanceAfterClaim - balanceBeforeClaim;

            // Verify claimed collateral matches remaining collateral
            assertEq(collateralClaimed, currentCollateral, "Claimed collateral should match remaining collateral");

            // Verify position is fully closed
            (uint256 finalCollateral, uint256 finalDebt) = nectraExternal.getPosition(tokens[i]);
            assertEq(finalCollateral, 0, "Position should have no remaining collateral");
            assertEq(finalDebt, 0, "Position should have no remaining debt");
        }

        // Due to 1 wei of rounding the last two positions will have some debt left
        nectra.modifyPosition(tokens[5], type(int256).min, type(int256).min, interestRates[5], "");
        (uint256 finalCollateral1, uint256 finalDebt1) = nectraExternal.getPosition(tokens[5]);
        assertEq(finalCollateral1, 0, "Position should have no remaining collateral");
        assertEq(finalDebt1, 0, "Position should have no remaining debt");

        // TODO: Last position cant fully withdraw due to rounding losses on collateral
        nectra.modifyPosition(tokens[6], type(int256).min, type(int256).min, interestRates[6], "");
        (uint256 finalCollateral2, uint256 finalDebt2) = nectraExternal.getPosition(tokens[6]);
        assertEq(finalCollateral2, 0, "Position should have no remaining collateral");
        assertEq(finalDebt2, 0, "Position should have no remaining debt");
    }
}
