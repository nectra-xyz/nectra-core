// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {IERC721} from "src/interfaces/IERC721.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";

contract NectraNFTTest is NectraBaseTest {
    address internal user2 = makeAddr("user2");
    uint256 internal positionIdUser2;

    uint256 internal whaleNumPositions = 9;
    uint256[] internal whalePositionIds = new uint256[](whaleNumPositions + 1);

    uint256 internal numNoisePositions = 5;

    function setUp() public override {
        super.setUp();

        // create random positions as noise
        for (uint256 i = 0; i < numNoisePositions; i++) {
            nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, 0.05 ether, "");
        }

        // Create NFTs for Whale
        deal(whale, 1_000 ether);

        for (uint256 i = 0; i < whaleNumPositions; i++) {
            vm.prank(whale);
            (whalePositionIds[i],,,,) = nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, 0.05 ether, "");
        }

        // Create NFTs for User 2
        deal(user2, 100 ether);

        vm.prank(user2);
        (positionIdUser2,,,,) = nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, 0.05 ether, "");
    }

    function test_authorize_revert_if_not_owner() public {
        vm.expectRevert(NectraNFT.NotOwner.selector);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);
    }

    function test_authorize_revert_if_invalid_permission() public {
        (bool success,) = address(nectraNFT).call(
            abi.encodeWithSignature("authorize(uint256,address,uint8)", whalePositionIds[0], address(this), 1337)
        );
        assertFalse(success, "Expected revert");
    }

    function test_transfer_revert_if_not_owner() public {
        address void = makeAddr("void");

        vm.expectRevert(IERC721.TransferFromIncorrectOwner.selector);
        nectraNFT.transferFrom(address(this), void, whalePositionIds[0]);
    }

    function test_transfer_revert_if_address_zero() public {
        vm.startPrank(whale);
        vm.expectRevert(IERC721.TransferToZeroAddress.selector);
        nectraNFT.transferFrom(whale, address(0), whalePositionIds[0]);
        vm.stopPrank();
    }

    function test_transfer_if_approved_success() public {
        address void = makeAddr("void");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");

        vm.prank(whale);
        nectraNFT.approve(address(this), whalePositionIds[0]);

        nectraNFT.transferFrom(whale, void, whalePositionIds[0]);

        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), void, "Expected to be transferred to void");
    }

    function test_transfer_revokes_all_permissions() public {
        vm.startPrank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Repay);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest);
        vm.stopPrank();

        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );
        address void = makeAddr("void");

        vm.prank(whale);
        nectraNFT.safeTransferFrom(whale, void, whalePositionIds[0]);

        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), void, "Expected to be transferred to void");

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be revoked"
        );
    }

    function test_mint_revert_if_not_nectra() public {
        vm.expectRevert(NectraNFT.NotAuthorizedMinter.selector);
        nectraNFT.mint(address(this));
    }

    function test_mint_revert_if_address_zero() public {
        vm.prank(address(nectra));
        vm.expectRevert(IERC721.TransferToZeroAddress.selector);
        nectraNFT.mint(address(0));
    }

    function test_authorize_borrow_permission() public {
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should NOTbe authorized"
        );

        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);

        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should NOT be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should NOT be authorized"
        );
    }

    function test_authorize_repay_permission() public {
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should NOT be authorized"
        );

        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Repay);

        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should NOT be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should NOT be authorized"
        );
    }

    function test_authorize_adjust_interest_permission() public {
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should NOT be authorized before"
        );

        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest);

        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should NOT be authorized"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should NOT be authorized"
        );
    }

    function test_authorize_all_valid_permissions() public {
        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);
        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.Repay);
        vm.prank(whale);
        nectraNFT.authorize(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest);

        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );
    }

    function test_revoke_borrow_permission() public {
        test_authorize_all_valid_permissions();

        vm.prank(whale);
        nectraNFT.revoke(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be revoked"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );
    }

    function test_revoke_all_after_revoke_borrow_permission() public {
        test_authorize_all_valid_permissions();

        vm.prank(whale);
        nectraNFT.revoke(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be revoked"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );

        vm.prank(whale);
        nectraNFT.revokeAll(whalePositionIds[0]);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be revoked"
        );
    }

    function test_revoke_repay_permission() public {
        test_authorize_all_valid_permissions();

        vm.prank(whale);
        nectraNFT.revoke(whalePositionIds[0], address(this), NectraNFT.Permission.Repay);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be revoked"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be authorized"
        );
    }

    function test_revoke_adjust_interest_permission() public {
        test_authorize_all_valid_permissions();

        vm.prank(whale);
        nectraNFT.revoke(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be revoked"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be authorized"
        );
        assertTrue(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be authorized"
        );
    }

    function test_revoke_all_permissions() public {
        test_authorize_all_valid_permissions();

        vm.prank(whale);
        nectraNFT.revokeAll(whalePositionIds[0]);

        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Borrow),
            "Borrow should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.Repay),
            "Repay should be revoked"
        );
        assertFalse(
            nectraNFT.authorized(whalePositionIds[0], address(this), NectraNFT.Permission.AdjustInterest),
            "AdjustInterest should be revoked"
        );
    }

    function test_balance_of_initial() public view {
        assertEq(nectraNFT.balanceOf(whale), whaleNumPositions, "Whale balance incorrect");
        assertEq(nectraNFT.balanceOf(user2), 1, "user2 balance incorrect");
        assertEq(nectraNFT.balanceOf(address(this)), numNoisePositions, "Test contract balance incorrect");
    }

    function test_balance_of_after_transfer() public {
        address recipient = makeAddr("recipient");

        vm.prank(whale);
        nectraNFT.safeTransferFrom(whale, recipient, whalePositionIds[0]);

        assertEq(nectraNFT.balanceOf(whale), whaleNumPositions - 1, "Whale balance should be 1 less after transfer");
        assertEq(nectraNFT.balanceOf(recipient), 1, "Recipient balance incorrect after transfer");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), recipient, "Position should be transferred to recipient");
    }

    function test_balance_of_revert_zero_address() public {
        vm.expectRevert(IERC721.BalanceQueryForZeroAddress.selector);
        nectraNFT.balanceOf(address(0));
    }

    function test_token_uri_exists() public view {
        // NectraNFT currently returns empty string
        assertEq(nectraNFT.tokenURI(whalePositionIds[0]), "", "Token URI should be empty string");
        assertEq(nectraNFT.tokenURI(positionIdUser2), "", "Token URI should be empty string");
    }

    // --- Approve / GetApproved ---
    function test_get_approved_initial() public view {
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), address(0), "Initial approval should be zero address");
    }

    function test_approve_success() public {
        address operator = address(this);
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), address(0), "Initial approval should be zero address");

        vm.prank(whale); // Owner approves
        nectraNFT.approve(operator, whalePositionIds[0]);

        assertEq(nectraNFT.getApproved(whalePositionIds[0]), operator, "Approved address mismatch");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");
    }

    function test_approve_updates() public {
        address operator1 = address(this);
        address operator2 = makeAddr("operator2");

        vm.startPrank(whale);
        nectraNFT.approve(operator1, whalePositionIds[0]);
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), operator1, "First approval failed");

        nectraNFT.approve(operator2, whalePositionIds[0]);
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), operator2, "Second approval failed");
        vm.stopPrank();
    }

    function test_approve_clear() public {
        address operator = address(this);
        vm.startPrank(whale);
        nectraNFT.approve(operator, whalePositionIds[0]);
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), operator, "Approval before clear failed");

        nectraNFT.approve(address(0), whalePositionIds[0]);
        assertEq(nectraNFT.getApproved(whalePositionIds[0]), address(0), "Clear approval failed");
        vm.stopPrank();
    }

    function test_approve_revert_not_owner() public {
        address operator = address(this);

        vm.startPrank(user2);
        vm.expectRevert(IERC721.NotOwnerNorApproved.selector);
        nectraNFT.approve(operator, whalePositionIds[0]);
        vm.stopPrank();
    }

    function test_approve_revert_nonexistent_token() public {
        address operator = address(this);
        uint256 nonExistentTokenId = 9999;

        vm.prank(whale);
        vm.expectRevert(IERC721.TokenDoesNotExist.selector);
        nectraNFT.approve(operator, nonExistentTokenId);
    }

    function test_approve_by_approved_for_all() public {
        address operator = address(this); // Test contract
        address approver = makeAddr("approver");

        // Whale approves operator for all
        vm.prank(whale);
        nectraNFT.setApprovalForAll(approver, true);

        // Operator approves 'approver' for the specific token
        vm.prank(approver);
        nectraNFT.approve(operator, whalePositionIds[0]);

        assertEq(nectraNFT.getApproved(whalePositionIds[0]), operator, "Approve by approvedForAll failed");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");
        assertEq(nectraNFT.isApprovedForAll(whale, approver), true, "ApprovedForAll should be true");
    }

    function test_get_approved_revert_nonexistent_token() public {
        uint256 nonExistentTokenId = 9999;
        vm.expectRevert(IERC721.TokenDoesNotExist.selector);
        nectraNFT.getApproved(nonExistentTokenId);
    }

    // --- SetApprovalForAll / IsApprovedForAll ---
    function test_set_approval_for_all_success() public {
        address operator = address(this);
        assertFalse(nectraNFT.isApprovedForAll(whale, operator), "Initial approval for operator should be false");

        vm.prank(whale);
        nectraNFT.setApprovalForAll(operator, true);

        assertTrue(nectraNFT.isApprovedForAll(whale, operator), "Approval for operator failed");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");
    }

    function test_set_approval_for_all_unset() public {
        address operator = address(this);
        assertFalse(nectraNFT.isApprovedForAll(whale, operator), "Initial approval for operator should be false");

        vm.startPrank(whale);
        // Set
        nectraNFT.setApprovalForAll(operator, true);
        assertTrue(nectraNFT.isApprovedForAll(whale, operator), "Set approval failed");

        // Unset
        nectraNFT.setApprovalForAll(operator, false);
        assertFalse(nectraNFT.isApprovedForAll(whale, operator), "Unset approval failed");
        vm.stopPrank();

        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");
    }

    function test_set_approval_for_all_idempotent() public {
        address operator = address(this);

        vm.startPrank(whale);
        // Set twice
        nectraNFT.setApprovalForAll(operator, true);
        nectraNFT.setApprovalForAll(operator, true);
        assertTrue(nectraNFT.isApprovedForAll(whale, operator), "Idempotent set failed");

        // Unset twice
        nectraNFT.setApprovalForAll(operator, false);
        nectraNFT.setApprovalForAll(operator, false);
        assertFalse(nectraNFT.isApprovedForAll(whale, operator), "Idempotent unset failed");
        vm.stopPrank();
    }

    function test_set_approval_for_all_self_succeeds() public {
        vm.prank(whale);
        nectraNFT.setApprovalForAll(whale, true);

        assertTrue(nectraNFT.isApprovedForAll(whale, whale), "Self setApprovalForAll should succeed");
        assertEq(nectraNFT.ownerOf(whalePositionIds[0]), whale, "Should be owned by whale");
    }

    function test_authorized_bitmask_zero_value() public {
        address operator = makeAddr("operator");

        assertEq(nectraNFT.authorized(whalePositionIds[0], operator, 0), false, "Expected to be unauthorized");
    }

    function test_getTokenIdsForAddress() public {
        uint256[] memory tokenIds = nectraNFT.getTokenIdsForAddress(whale);
        assertEq(tokenIds.length, whaleNumPositions);

        for (uint256 i = 0; i < whaleNumPositions; i++) {
            assertEq(tokenIds[i], whalePositionIds[i]);
        }
    }

    function test_should_reduce_list_size_when_token_is_burned() public {
        // Burn all positions
        for (uint256 i = 0; i < whaleNumPositions; i++) {
            vm.prank(whale);
            nectraNFT.transferFrom(whale, address(1), whalePositionIds[i]);

            uint256[] memory tokenIds = nectraNFT.getTokenIdsForAddress(whale);
            assertEq(tokenIds.length, whaleNumPositions - (i + 1));
            _checkAllTokensArePresent(tokenIds);
        }
    }

    function test_should_increase_list_size_when_token_is_minted() public {
        // Mint a new token
        vm.prank(whale);
        (whalePositionIds[whaleNumPositions],,,,) =
            nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, 0.05 ether, "");
        whaleNumPositions++;

        uint256[] memory tokenIds = nectraNFT.getTokenIdsForAddress(whale);
        assertEq(tokenIds.length, whaleNumPositions);
        _checkAllTokensArePresent(tokenIds);
    }

    function test_should_increase_list_size_when_token_is_received_from_other_address() public {
        // Mint a new token
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: 10 ether}(0, 10 ether, 1 ether, 0.05 ether, "");
        nectraNFT.transferFrom(address(this), whale, tokenId);
        whalePositionIds[whaleNumPositions] = tokenId;
        whaleNumPositions++;

        uint256[] memory tokenIds = nectraNFT.getTokenIdsForAddress(whale);
        assertEq(tokenIds.length, whaleNumPositions);
        _checkAllTokensArePresent(tokenIds);
    }

    function test_getPositionsForAddress() public {
        NectraExternal.PositionData[] memory positions = nectraExternal.getPositionsForAddress(whale);
        assertEq(positions.length, whaleNumPositions);

        for (uint256 i = 0; i < whaleNumPositions; i++) {
            assertEq(positions[i].tokenId, whalePositionIds[i]);
            assertEq(positions[i].collateral, 10 ether);
            assertEq(positions[i].debt, 1 ether);
        }
    }

    function _checkAllTokensArePresent(uint256[] memory tokenIds) internal {
        uint256 foundCount = 0;

        for (uint256 j = 0; j < tokenIds.length; j++) {
            for (uint256 k = 0; k < whaleNumPositions; k++) {
                if (tokenIds[j] == whalePositionIds[k]) {
                    foundCount++;
                }
            }
        }

        assertEq(foundCount, tokenIds.length);
    }
}
