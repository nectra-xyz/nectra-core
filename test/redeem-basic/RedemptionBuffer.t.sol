// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console} from "test/NectraBase.t.sol";

import {NectraLib} from "src/NectraLib.sol";

import {Ownable} from "src/lib/Ownable.sol";

import {INectra} from "src/interfaces/INectra.sol";

contract RedemptionBufferTest is NectraBaseTest {
    address internal dao;
    address internal manager;
    address internal notDao;

    function setUp() public virtual override {
        super.setUp();
        dao = address(this);
        manager = makeAddr("manager");
        notDao = makeAddr("notDao");
    }

    // 1. confirm only dao can create buffer position, should fail otherwise
    function test_onlyDaoCanSetBuffer() public {
        // non-dao cannot create buffer
        vm.deal(notDao, 10 ether);
        vm.prank(notDao);
        vm.expectRevert(abi.encodeWithSelector(Ownable.Unauthorized.selector, notDao));
        nectra.storeRedemptionBuffer(0, manager);

        // dao succeeds
        uint256 tokenId = _createBuffer(10 ether, 1 ether, manager);
        _checkPosition(tokenId, 10 ether, 1 ether, 0);
    }

    // 2. confirm position does not accrue interest or open fee
    function test_bufferDoesNotAccrueInterestOrOpenFee() public {
        uint256 tokenId = _createBuffer(10 ether, 1 ether, manager);

        // manager borrows; no open fee should be applied and interest rate is 0%
        vm.prank(manager);
        nectra.modifyPosition(tokenId, 0, 2 ether, "");

        // warp and update position; no interest should accrue
        vm.warp(block.timestamp + 30 days);
        nectra.updatePosition(tokenId);

        // check position after
        _checkPosition(tokenId, 10 ether, 3 ether, 0);
    }

    // 3. confirm the buffer position does not migrate bucket when its debt increases or collateral decreases
    function test_bufferDoesNotMigrateOnBorrowOrWithdraw() public {
        uint256 tokenId = _createBuffer(10 ether, 1 ether, manager);

        _checkPosition(tokenId, 10 ether, 1 ether, 0);

        // borrowing
        vm.prank(manager);
        nectra.modifyPosition(tokenId, 0, 1 ether, "");
        _checkPosition(tokenId, 10 ether, 2 ether, 0);

        // withdraw
        vm.prank(manager);
        nectra.modifyPosition(tokenId, -1 ether, 0, "");
        _checkPosition(tokenId, 9 ether, 2 ether, 0);
    }

    // 4. ensure the redemption buffer position is redeemed entirely before rest of system is affected by redemptions
    function test_redemptionsHitBufferBeforeOtherBuckets() public {
        address user = makeAddr("user");

        // Create buffer with debt and another user bucket with debt
        uint256 bufferTokenId = _createBuffer(10 ether, 5 ether, manager);
        _checkPosition(bufferTokenId, 10 ether, 5 ether, 0);

        uint256 userRate = nectra.getSystemInterestRate();
        uint256 userTokenId = _createPosition(user, 10 ether, 5 ether, userRate);
        _checkPosition(userTokenId, 10 ether, 5 ether, userRate);

        // Record pre redemption debts
        uint256 bufferDebtBefore = nectraExternal.getPositionDebt(bufferTokenId);
        uint256 userBucketDebtBefore = nectraExternal.getBucketDebt(userRate);

        // Perform redemption smaller than buffer debt
        uint256 redeemAmount = 5 ether;
        vm.startPrank(user);
        nectraUSD.approve(address(nectra), redeemAmount);
        nectra.redeem(redeemAmount, 0);
        vm.stopPrank();

        // Buffer should absorb redemption fully; other bucket unchanged
        uint256 bufferDebtAfter = nectraExternal.getPositionDebt(bufferTokenId);
        uint256 userBucketDebtAfter = nectraExternal.getBucketDebt(userRate);
        assertLt(bufferDebtAfter, bufferDebtBefore, "Buffer debt should be reduced first");
        assertEq(userBucketDebtAfter, userBucketDebtBefore, "Other buckets should be unaffected until buffer empties");
    }

    // 5. ensure that if the buffer manager address is changed only the new manager can manage the position
    function test_onlyNewManagerCanManageAfterChange() public {
        uint256 tokenId = _createBuffer(10 ether, 1 ether, manager);

        address newManager = makeAddr("newManager");
        nectra.storeRedemptionBuffer(tokenId, newManager);

        // old manager cannot manage anymore
        vm.prank(manager);
        vm.expectRevert(INectra.NotOwnerNorApproved.selector);
        nectra.modifyPosition(tokenId, 0, 2 ether, "");

        // new manager can manage
        vm.prank(newManager);
        nectra.modifyPosition(tokenId, 0, 3 ether, "");
        _checkPosition(tokenId, 10 ether, 4 ether, 0);
    }

    // 6. if buffer position id is changed, new buffer gets 0% on next modify; old buffer uses system IR on next modify
    function test_changingBufferIdUpdatesWhichPositionIs0Percent() public {
        uint256 systemIR = nectra.getSystemInterestRate();

        // Create two positions
        uint256 a = _createBuffer(10 ether, 1 ether, manager);
        uint256 b = _createPosition(address(this), 10 ether, 1 ether, systemIR);

        // Modify A as manager -> stays at 0%
        vm.prank(manager);
        nectra.modifyPosition(a, 0, 1 ether, "");
        _checkPosition(a, 10 ether, 2 ether, 0);

        // Change buffer id to B
        nectra.storeRedemptionBuffer(b, manager);

        // Modify B as manager -> 0%
        vm.prank(manager);
        nectra.modifyPosition(b, 0, 2 ether, "");
        _checkPosition(b, 10 ether, 3 ether, 0);

        // Modify A now (not buffer) -> should use system IR (non-zero)
        systemIR = nectra.getSystemInterestRate();
        // manager still owns the NFT for this position but it will no longer
        // be in the 0% bucket
        vm.prank(manager);
        nectra.modifyPosition(a, 0, 3 ether, "");
        _checkPosition(a, 10 ether, 5 ether, systemIR);
    }
}
