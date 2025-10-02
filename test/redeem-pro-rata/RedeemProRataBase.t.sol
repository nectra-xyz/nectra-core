// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest} from "test/NectraBase.t.sol";
import {NectraLib} from "src/NectraLib.sol";

import {console} from "forge-std/console.sol";

contract RedeemProRataBaseTest is NectraBaseTest {
    uint256 internal bufferTokenId;

    address internal manager;

    uint256[] internal tokens;
    uint256[] internal interestRates;
    uint256[] internal debt;
    uint256[] internal collateral;
    address[] internal users;

    uint256 internal redemptionBufferCollateral;
    uint256 internal redemptionBufferDebt;

    uint256 internal price;

    function setUp() public virtual override {
        super.setUp();

        manager = address(this);

        // set array lengths
        assembly {
            sstore(tokens.slot, 5)
            sstore(interestRates.slot, 5)
            sstore(debt.slot, 5)
            sstore(collateral.slot, 5)
            sstore(users.slot, 5)
        }

        (users[0], collateral[0], debt[0], interestRates[0]) = (
            makeAddr("user0"),
            200 ether,
            150 ether,
            systemParams.minimumInterestRate + 10 * systemParams.interestRateIncrement
        );
        (users[1], collateral[1], debt[1], interestRates[1]) = (
            makeAddr("user1"),
            200 ether,
            50 ether,
            systemParams.minimumInterestRate + 13 * systemParams.interestRateIncrement
        );
        (users[2], collateral[2], debt[2], interestRates[2]) = (
            makeAddr("user2"),
            200 ether,
            100 ether,
            systemParams.minimumInterestRate + 50 * systemParams.interestRateIncrement
        );
        (users[3], collateral[3], debt[3], interestRates[3]) = (
            makeAddr("user3"),
            200 ether,
            100 ether,
            systemParams.minimumInterestRate + 73 * systemParams.interestRateIncrement
        );
        (users[4], collateral[4], debt[4], interestRates[4]) = (
            makeAddr("user4"),
            200 ether,
            100 ether,
            systemParams.minimumInterestRate + 74 * systemParams.interestRateIncrement
        );

        for (uint256 i = 0; i < interestRates.length; i++) {
            tokens[i] = _createPosition(users[i], collateral[i], debt[i], interestRates[i]);

            vm.prank(users[i]);
            // send each users nUSD to this contract to test redemptions
            nectraUSD.transfer(address(this), debt[i]);
        }

        // Create buffer at 0% with 100 debt
        redemptionBufferCollateral = 200 ether;
        redemptionBufferDebt = 100 ether;
        vm.deal(address(this), redemptionBufferCollateral);

        (bufferTokenId,,,,) = nectra.createRedemptionBufferPosition{value: redemptionBufferCollateral}(
            redemptionBufferCollateral, redemptionBufferDebt, manager
        );

        // Unlimited approval for redemptions
        nectraUSD.approve(address(nectra), type(uint256).max);

        (price,) = oracle.getLatestPrice();
    }

    function _debt(uint256 tokenId) internal view returns (uint256) {
        return nectraExternal.getPositionDebt(tokenId);
    }

    function _collateral(uint256 tokenId) internal view returns (uint256) {
        return nectraExternal.getPositionCollateral(tokenId);
    }

    function _bucketDebt(uint256 rate) internal view returns (uint256) {
        return nectraExternal.getBucketDebt(rate);
    }

    function _getDebts(uint256[] memory tokenIds) internal view returns (uint256[] memory) {
        uint256[] memory debts = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            debts[i] = _debt(tokenIds[i]);
        }
        return debts;
    }

    function _getCollaterals(uint256[] memory tokenIds) internal view returns (uint256[] memory) {
        uint256[] memory collaterals = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            collaterals[i] = _collateral(tokenIds[i]);
        }
        return collaterals;
    }

    function _checkDebts(uint256[] memory tokenIds, uint256[] memory expectedDebts) internal view {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            assertApproxEqRel(
                _debt(tokenIds[i]),
                expectedDebts[i],
                1e11,
                string.concat("debt mismatch for token ", _toString(i))
            );
        }
    }

    function _checkCollaterals(uint256[] memory tokenIds, uint256[] memory expectedCollaterals) internal view {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            assertApproxEqRel(
                _collateral(tokenIds[i]),
                expectedCollaterals[i],
                1e11,
                string.concat("collateral mismatch for token ", _toString(i))
            );
        }
    }

    function _checkCanWithDrawCollateral(uint256 tokenId) internal {
        address user = nectraNFT.ownerOf(tokenId);
        uint256 balanceBefore = user.balance;
        uint256 collateralBefore = _collateral(tokenId);
        vm.prank(user);
        nectra.modifyPosition(tokenId, type(int256).min, type(int256).min, "");

        assertEq(user.balance, balanceBefore + collateralBefore, "Position should have received collateral");
        assertEq(_collateral(tokenId), 0 ether, "Position should have no collateral");
        assertEq(_debt(tokenId), 0 ether, "Position should have no debt");
    }

    function _checkCanWithdrawAllCollateral() internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            _checkCanWithDrawCollateral(tokens[i]);
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (value != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buf);
    }

    function _getExpectedFeePercentage(uint256 redemptionAmount) internal virtual returns (uint256) {}
}
