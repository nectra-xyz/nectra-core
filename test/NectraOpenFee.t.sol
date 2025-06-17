// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

contract NectraOpenFeeTest is NectraBaseTest {
    function setUp() public virtual override {
        cargs.openFeePercentage = 0.005 ether; // 0.5%
        super.setUp();
    }

    function test_open_fee_is_charged() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");

        ( /*int256 collateralDiff*/ , int256 debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.1 ether);

        // open fee = 0.5% of 100 ether = 0.5 ether
        assertApproxEqRel(-debtDiff, 100 ether + 0.5 ether, 1e11);

        // half debt, half fee
        //(, debtDiff,,) = nectra.quoteModifyPosition(tokenId, 1000 ether, -50 ether, 0.1 ether);
        //assertApproxEqRel(-debtDiff, (100 ether + 0.5 ether) / 2, 1e11);

        // increase debt
        (,, debtDiff,,) = nectra.modifyPosition(tokenId, 0 ether, 100 ether, 0.1 ether, "");
        assertApproxEqRel(debtDiff, 100 ether, 1e11);

        // decrease debt
        (, debtDiff,,) = nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.1 ether);
        assertApproxEqRel(-debtDiff, 200 ether + 1 ether, 1e11);
    }

    function test_open_fee_not_charged_if_expired() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");

        vm.warp(vm.getBlockTimestamp() + 365 days);

        uint256 positionDebt = nectraExternal.getPositionDebt(tokenId);
        assertApproxEqRel(positionDebt, 110 ether, 1e11);

        ( /*int256 collateralDiff*/ , int256 debtDiff,,) = nectra.quoteModifyPosition(tokenId, 0 ether, 0, 0.2 ether);
        assertApproxEqAbs(uint256(-debtDiff), 0, 1);

        ( /*int256 collateralDiff*/ , debtDiff,,) = nectra.quoteModifyPosition(tokenId, 0 ether, 0, 0.05 ether);
        assertApproxEqAbs(uint256(-debtDiff), 0, 1);

        ( /*int256 collateralDiff*/ , debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
        assertApproxEqAbs(uint256(-debtDiff), positionDebt, 1);
    }

    /**
     * Open fee is charged until interest accrued exceeds
     * the open fee.
     *
     * |--------------------------|
     * | interest rate is 5% p/a  |
     * | principal is $100       |
     * |--------------------------|
     * | time       | diff        |
     * |--------------------------|
     * | 0          | 100.5       |
     * | 86400      | 100.5       |
     * | 604800     | 100.5       |
     * | 2678400    | 100.5       |
     * | 5184000    | 100.805255  |
     * | 15811200   | 102.4763565 |
     * | 31536000   | 105         |
     * | 63072000   | 110.25      |
     * |--------------------------|*
     */
    function test_open_fee_overtime() public {
        uint256 startTime = vm.getBlockTimestamp();
        int256 debtDiff;

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.05 ether, "");

        uint256[8] memory timestamps;
        uint256[8] memory expected;

        (timestamps[0], expected[0]) = (0, 100.5 ether);
        (timestamps[1], expected[1]) = (86400, 100.5 ether);
        (timestamps[2], expected[2]) = (604800, 100.5 ether);
        (timestamps[3], expected[3]) = (2678400, 100.5 ether);
        (timestamps[4], expected[4]) = (5184000, 100.805255 ether);
        (timestamps[5], expected[5]) = (15811200, 102.4763565 ether);
        (timestamps[6], expected[6]) = (31536000, 105 ether);
        (timestamps[7], expected[7]) = (63072000, 110.25 ether);

        for (uint256 i = 0; i < expected.length; i++) {
            vm.warp(startTime + timestamps[i]);
            (, debtDiff,,) = nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.1 ether);
            assertApproxEqAbs(uint256(-debtDiff), expected[i], 1e11);
        }
    }

    function test_open_fee_fully_realized_when_reducing_interest() public {
        uint256 startTime = vm.getBlockTimestamp();
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");

        vm.warp(startTime + 1 days);
        nectra.modifyPosition(tokenId, 0, 0, 0.05 ether, "");

        ( /*int256 collateralDiff*/ , int256 debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
        assertApproxEqRel(uint256(-debtDiff), 101.0025 ether, 1e11, "1");

        vm.warp(startTime + 8 days);
        ( /*int256 collateralDiff*/ , debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
        assertApproxEqRel(uint256(-debtDiff), 101.0025 ether, 1e11, "2");

        vm.warp(startTime + 60 days);
        ( /*int256 collateralDiff*/ , debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
        // 100.5 * math.exp(math.log(1 + 0.05) * 59 / 365)
        assertApproxEqRel(uint256(-debtDiff), 101.29573997087438 ether, 1e11, "3");
        return;
    }

    /**
     * Should not incur an additional fee when migrating
     * to a higher interest rate. Shortens period
     * for which fee is applicable, as a higher interest
     * rate is applied.
     *
     * |---------------------------------------------------|
     * | interest rate is 5% p/a and 20% p/a after 1 day   |
     * | principal is $100                                 |
     * |---------------------------------------------------|
     * | time       | interest | debt                      |
     * |---------------------------------------------------|
     * | 0          | 5%       | 100                       |
     * | 86400      | 5%       | 100.0133681               |
     * | 604800     | 20%      | 100.3135644               |
     * | 2678400    | 20%      | 101.5233875               |
     * | 5184000    | 20%      | 103.0047407               |
     * | 15811200   | 20%      | 109.5317959               |
     * | 31536000   | 20%      | 119.9561073               |
     * | 63072000   | 20%      | 143.9473288               |
     * |---------------------------------------------------|
     */
    function test_open_fee_migrate_to_higher_bucket_overtime() public {
        uint256 startTime = vm.getBlockTimestamp();
        int256 debtDiff;

        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.05 ether, "");

        vm.warp(startTime + 86400);
        (,, debtDiff,,) = nectra.modifyPosition(tokenId, 0, 0, 0.2 ether, "");
        assertApproxEqRel(uint256(debtDiff), 0, 1e11, "1");

        (, debtDiff,,) = nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.2 ether);
        assertApproxEqRel(uint256(-debtDiff), 100.5 ether, 1e11, "2");

        uint256[6] memory timestamps;
        uint256[6] memory expected;

        (timestamps[0], expected[0]) = (604800, 100.5 ether);
        (timestamps[1], expected[1]) = (2678400, 101.5233875 ether);
        (timestamps[2], expected[2]) = (5184000, 103.0047407 ether);
        (timestamps[3], expected[3]) = (15811200, 109.5317959 ether);
        (timestamps[4], expected[4]) = (31536000, 119.9561073 ether);
        (timestamps[5], expected[5]) = (63072000, 143.9473288 ether);

        for (uint256 i = 0; i < expected.length; i++) {
            vm.warp(startTime + timestamps[i]);
            (, debtDiff,,) = nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.2 ether);
            assertApproxEqRel(uint256(-debtDiff), expected[i], 1e11);
        }
    }

    /**
     * Open fee is charged even if the position is partially
     * redeemed. Redemption does not reduce the open fee.
     * |---------------------------------------------------|
     * | interest rate is 5% p/a                           |
     * | principal is $100 and then $50 after redemptions  |
     * |---------------------------------------------------|
     * | time       | interest | debt                      |
     * |---------------------------------------------------|
     * | 0          | 5%       | 100                       |
     * | 0          | 5%       | 50                        |
     * | 86400      | 5%       | 50.00668403               |
     * | 604800     | 5%       | 50.04680698               |
     * | 2678400    | 5%       | 50.20762098               |
     * | 5184000    | 5%       | 50.40262749               |
     * | 6431500    | 5%       | 50.50000049               |
     * | 15811200   | 5%       | 51.23817826               |
     * | 31536000   | 5%       | 52.5                      |
     * | 63072000   | 5%       | 55.125                    |
     * |---------------------------------------------------|
     */
    function test_open_fee_with_redemption() public {
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.05 ether, "");
        uint256 startTime = vm.getBlockTimestamp();

        nectraUSD.approve(address(nectra), type(uint256).max);
        nectra.redeem(50 ether, 0 ether);

        uint256[9] memory timestamps;
        uint256[9] memory expectedDebt;

        (timestamps[0], expectedDebt[0]) = (0, 50.5 ether);
        (timestamps[1], expectedDebt[1]) = (86400, 50.5 ether);
        (timestamps[2], expectedDebt[2]) = (604800, 50.5 ether);
        (timestamps[3], expectedDebt[3]) = (2678400, 50.5 ether);
        (timestamps[4], expectedDebt[4]) = (5184000, 50.5 ether);
        (timestamps[5], expectedDebt[5]) = (6431500, 50.50000049 ether);
        (timestamps[6], expectedDebt[6]) = (15811200, 51.23817826 ether);
        (timestamps[7], expectedDebt[7]) = (31536000, 52.5 ether);
        (timestamps[8], expectedDebt[8]) = (63072000, 55.125 ether);

        for (uint256 i = 0; i < expectedDebt.length; i++) {
            vm.warp(startTime + timestamps[i]);
            ( /*int256 collateralDiff*/ , int256 debtDiff,,) =
                nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
            assertApproxEqRel(uint256(-debtDiff), expectedDebt[i], 1e11);

            assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), expectedDebt[i], 1e11, "1");
        }
    }

    function test_open_fee_charged_fully_redeemed() public {
        nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 100 ether, 0.1 ether, "");
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 1000 ether}(0, 1000 ether, 1 ether, 0.05 ether, "");

        nectraUSD.approve(address(nectra), type(uint256).max);
        nectra.redeem(2 ether, 0 ether);

        assertApproxEqRel(nectraExternal.getPositionDebt(tokenId), 0.005 ether, 1e11, "1");

        ( /*int256 collateralDiff*/ , int256 debtDiff,,) =
            nectra.quoteModifyPosition(tokenId, type(int256).min, type(int256).min, 0.05 ether);
        assertApproxEqRel(uint256(-debtDiff), 0.005 ether, 1e11, "2");
    }
}
