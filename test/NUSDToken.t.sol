// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken, ERC20} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";

contract NUSDTokenTest is NectraBaseTest {
    address internal user1;
    address internal user2;
    uint256 internal user1Pk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default #0
    uint256 internal initialMintAmount = 1000 ether;

    // EIP-712 STRUCT HASHES
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public virtual override {
        super.setUp();

        user1 = vm.addr(user1Pk);
        user2 = makeAddr("user2");

        // Mint initial tokens to user1 (assuming nectra is the minter)
        vm.prank(address(nectra));
        nectraUSD.mint(user1, initialMintAmount);
    }

    // --- View Functions ---
    function test_decimals() public view {
        assertEq(nectraUSD.decimals(), 18, "Decimals should be 18");
    }

    function test_total_supply() public view {
        assertEq(nectraUSD.totalSupply(), initialMintAmount, "Total supply should match initial mint");
    }

    function test_balance_of() public view {
        assertEq(nectraUSD.balanceOf(user1), initialMintAmount, "User1 balance incorrect");
        assertEq(nectraUSD.balanceOf(user2), 0, "User2 balance should be 0");
    }

    // --- Transfer ---
    function test_transfer_success() public {
        uint256 transferAmount = 123 ether;
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);
        uint256 user2InitialBalance = nectraUSD.balanceOf(user2);
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(user1);
        bool success = nectraUSD.transfer(user2, transferAmount);

        assertTrue(success, "Transfer failed");
        assertEq(
            nectraUSD.balanceOf(user1), user1InitialBalance - transferAmount, "User1 balance incorrect after transfer"
        );
        assertEq(
            nectraUSD.balanceOf(user2), user2InitialBalance + transferAmount, "User2 balance incorrect after transfer"
        );
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply should not change");
    }

    function test_transfer_zero_amount() public {
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);
        uint256 user2InitialBalance = nectraUSD.balanceOf(user2);
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(user1);
        bool success = nectraUSD.transfer(user2, 0);

        assertTrue(success, "Transferring 0 amount failed");
        assertEq(nectraUSD.balanceOf(user1), user1InitialBalance, "User1 balance changed unexpectedly");
        assertEq(nectraUSD.balanceOf(user2), user2InitialBalance, "User2 balance changed unexpectedly");
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply should not change");
    }

    function test_transfer_to_zero_address_succeeds() public {
        // Note: This base ERC20 implementation allows transfers to address(0)
        uint256 transferAmount = 100 ether;
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(user1);
        bool success = nectraUSD.transfer(address(0), transferAmount);

        assertTrue(success, "Transfer to address(0) failed");

        assertEq(
            nectraUSD.balanceOf(user1),
            user1InitialBalance - transferAmount,
            "User1 balance incorrect after transfer to zero"
        );
        // Balance of address(0) increases, but often not tracked/queried directly.
        // Total supply remains the same.
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply changed unexpectedly");
    }

    function test_transfer_insufficient_balance_failure() public {
        uint256 transferAmount = initialMintAmount + 1 ether; // More than user1 has
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        nectraUSD.transfer(user2, transferAmount);

        assertEq(nectraUSD.balanceOf(user1), user1InitialBalance, "User1 balance changed unexpectedly");
    }

    function test_transfer_to_self() public {
        uint256 transferAmount = 100 ether;
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(user1);
        bool success = nectraUSD.transfer(user1, transferAmount);

        assertTrue(success, "Transfer to self failed");

        // Balance should remain unchanged
        assertEq(nectraUSD.balanceOf(user1), user1InitialBalance, "User1 balance changed unexpectedly");
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply changed unexpectedly");
    }

    // --- Approve / Allowance ---
    function test_approve_success() public {
        uint256 approveAmount = 50 ether;
        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);

        vm.prank(user1);
        bool success = nectraUSD.approve(user2, approveAmount);

        assertTrue(success, "Approve failed");
        assertEq(nectraUSD.allowance(user1, user2), approveAmount, "Allowance incorrect");
        assertEq(nectraUSD.balanceOf(user1), user1InitialBalance, "User1 balance changed unexpectedly");
    }

    function test_allowance_initial() public view {
        assertEq(nectraUSD.allowance(user1, user2), 0, "Initial allowance should be 0");
        assertEq(nectraUSD.allowance(user2, user1), 0, "Initial allowance should be 0");
    }

    function test_approve_zero_amount_success() public {
        uint256 allowanceAmount = 100 ether;

        vm.prank(user1);
        bool success = nectraUSD.approve(user2, allowanceAmount);

        assertTrue(success, "Approve zero amount failed");
        assertEq(nectraUSD.allowance(user1, user2), allowanceAmount, "Allowance should be 100 after approval");

        vm.prank(user1);
        success = nectraUSD.approve(user2, 0);

        assertTrue(success, "Approve zero amount failed");
        assertEq(nectraUSD.allowance(user1, user2), 0, "Allowance should be 0 after zero approval");
    }

    function test_approve_to_zero_address_succeeds() public {
        // Note: This base ERC20 implementation allows approvals to address(0)
        uint256 approveAmount = 50 ether;

        vm.prank(user1);
        bool success = nectraUSD.approve(address(0), approveAmount);

        assertTrue(success, "Approve to address(0) failed");
        assertEq(nectraUSD.allowance(user1, address(0)), approveAmount, "Allowance for address(0) incorrect");
    }

    function test_approve_self_succeeds() public {
        // Note: This base ERC20 implementation allows self-approvals
        uint256 approveAmount = 50 ether;

        vm.prank(user1);
        bool success = nectraUSD.approve(user1, approveAmount);

        assertTrue(success, "Self-approve failed");
        assertEq(nectraUSD.allowance(user1, user1), approveAmount, "Self-allowance incorrect");
    }

    function test_approve_updates_allowance() public {
        uint256 firstAmount = 50 ether;
        uint256 secondAmount = 100 ether;

        vm.startPrank(user1);
        nectraUSD.approve(user2, firstAmount);
        assertEq(nectraUSD.allowance(user1, user2), firstAmount, "First allowance incorrect");

        nectraUSD.approve(user2, secondAmount);
        assertEq(nectraUSD.allowance(user1, user2), secondAmount, "Second allowance incorrect");
        vm.stopPrank();
    }

    // --- Mint / Burn ---
    function test_mint_revert_if_not_minter() public {
        vm.expectRevert(NUSDToken.NotMinter.selector);
        nectraUSD.mint(address(this), 1 ether);
    }

    function test_burn_revert_if_not_minter() public {
        vm.expectRevert(NUSDToken.NotMinter.selector);
        nectraUSD.burn(address(this), 1 ether);
    }

    function test_mint_success(uint256 mintAmount) public {
        vm.assume(mintAmount >= 0);
        vm.assume(mintAmount <= type(uint128).max);

        uint256 initialBalance = nectraUSD.balanceOf(address(this));
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(address(nectra));
        nectraUSD.mint(address(this), mintAmount);

        assertEq(
            nectraUSD.balanceOf(address(this)),
            initialBalance + mintAmount,
            "Expected balance to increase by mint amount"
        );
        assertEq(
            nectraUSD.totalSupply(), totalSupplyInitial + mintAmount, "Total supply should increase by mint amount"
        );
    }

    function test_burn_requires_allowance() public {
        uint256 burnAmount = 1 ether;
        test_mint_success(burnAmount);

        uint256 initialBalance = nectraUSD.balanceOf(address(this));
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        vm.prank(address(nectra));
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        nectraUSD.burn(address(this), burnAmount);

        assertEq(nectraUSD.balanceOf(address(this)), initialBalance, "Expected balance to be unchanged");
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply should be unchanged");
    }

    function test_burn_success() public {
        uint256 burnAmount = 1 ether;
        test_mint_success(burnAmount);

        uint256 initialBalance = nectraUSD.balanceOf(address(this));
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        nectraUSD.approve(address(nectra), burnAmount);

        vm.prank(address(nectra));
        nectraUSD.burn(address(this), burnAmount);

        assertEq(
            nectraUSD.balanceOf(address(this)), initialBalance - burnAmount, "Expected balance to reduce by burn amount"
        );
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial - burnAmount, "Total supply should reduce by burn amount");
    }

    // --- TransferFrom ---
    function test_transfer_from_success(uint256 approveAmount, uint256 transferAmount) public {
        vm.assume(approveAmount >= transferAmount);
        vm.assume(transferAmount >= 0);
        vm.assume(approveAmount <= type(uint128).max);

        vm.prank(address(nectra));
        nectraUSD.mint(user1, transferAmount);

        uint256 user1InitialBalance = nectraUSD.balanceOf(user1);
        uint256 user2InitialBalance = nectraUSD.balanceOf(user2);
        uint256 totalSupplyInitial = nectraUSD.totalSupply();

        // User1 approves User2
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        // User2 transfers from User1 to themselves
        vm.prank(user2);
        bool success = nectraUSD.transferFrom(user1, user2, transferAmount);

        assertTrue(success, "TransferFrom failed");
        assertEq(nectraUSD.balanceOf(user1), user1InitialBalance - transferAmount, "User1 balance incorrect");
        assertEq(nectraUSD.balanceOf(user2), user2InitialBalance + transferAmount, "User2 balance incorrect");
        assertEq(nectraUSD.allowance(user1, user2), approveAmount - transferAmount, "Allowance not reduced correctly");
        assertEq(nectraUSD.totalSupply(), totalSupplyInitial, "Total supply should not change");
    }

    function test_transfer_from_to_other_success() public {
        uint256 approveAmount = 100 ether;
        uint256 transferAmount = 50 ether;
        address user3 = makeAddr("user3");

        // User1 approves User2
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        // User2 transfers from User1 to User3
        vm.prank(user2);
        bool success = nectraUSD.transferFrom(user1, user3, transferAmount);

        assertTrue(success, "TransferFrom failed");
        assertEq(nectraUSD.balanceOf(user1), initialMintAmount - transferAmount, "User1 balance incorrect");
        assertEq(nectraUSD.balanceOf(user2), 0, "User2 balance should be unchanged");
        assertEq(nectraUSD.balanceOf(user3), transferAmount, "User3 balance incorrect");
        assertEq(nectraUSD.allowance(user1, user2), approveAmount - transferAmount, "Allowance not reduced correctly");
    }

    function test_transfer_from_zero_amount_success() public {
        uint256 approveAmount = 100 ether;
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        vm.prank(user2);
        bool success = nectraUSD.transferFrom(user1, user2, 0);

        assertTrue(success, "TransferFrom zero amount failed");
        assertEq(nectraUSD.balanceOf(user1), initialMintAmount, "User1 balance changed unexpectedly");
        assertEq(nectraUSD.balanceOf(user2), 0, "User2 balance changed unexpectedly");
        assertEq(nectraUSD.allowance(user1, user2), approveAmount, "Allowance changed unexpectedly");
    }

    function test_transfer_from_to_zero_address_succeeds() public {
        // Note: This base ERC20 implementation allows transfers to address(0)
        uint256 approveAmount = 100 ether;
        uint256 transferAmount = 50 ether;
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        vm.prank(user2);
        bool success = nectraUSD.transferFrom(user1, address(0), transferAmount);
        assertTrue(success, "TransferFrom to zero address failed");

        assertEq(nectraUSD.balanceOf(user1), initialMintAmount - transferAmount, "User1 balance incorrect");
        assertEq(nectraUSD.allowance(user1, user2), approveAmount - transferAmount, "Allowance not reduced correctly");
    }

    // Note: Transferring *from* zero address is usually impossible as address(0) cannot approve.
    // However, if somehow address(0) had a balance and allowance was set (not standard),
    // the base ERC20 might allow it. Skipping this non-standard test.

    function test_transfer_from_insufficient_allowance() public {
        uint256 approveAmount = 50 ether;
        uint256 transferAmount = 100 ether; // More than allowance
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        vm.prank(user2);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        nectraUSD.transferFrom(user1, user2, transferAmount);
    }

    function test_transfer_from_insufficient_balance() public {
        uint256 approveAmount = initialMintAmount + 100 ether; // Ample allowance
        uint256 transferAmount = initialMintAmount + 1 ether; // More than balance
        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);

        vm.prank(user2);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        nectraUSD.transferFrom(user1, user2, transferAmount);
    }

    function test_transfer_from_allowance_not_infinite_success() public {
        uint256 approveAmount = type(uint256).max; // Infinite allowance
        uint256 transferAmount = 50 ether;

        vm.prank(user1);
        nectraUSD.approve(user2, approveAmount);
        assertEq(nectraUSD.allowance(user1, user2), type(uint256).max, "Allowance should be max");

        vm.prank(user2);
        bool success = nectraUSD.transferFrom(user1, user2, transferAmount);
        assertTrue(success, "TransferFrom failed with max allowance");

        // Check balances
        assertEq(nectraUSD.balanceOf(user1), initialMintAmount - transferAmount, "User1 balance incorrect");
        assertEq(nectraUSD.balanceOf(user2), transferAmount, "User2 balance incorrect");

        // Check allowance is NOT reduced if it was infinite
        assertEq(nectraUSD.allowance(user1, user2), type(uint256).max, "Max allowance was reduced");
    }

    // --- Increase/Decrease Allowance ---

    // --- Permit (EIP-2612) ---

    function test_permit_happy_path() public {
        uint256 approveAmount = 100 ether;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        uint256 nonce = nectraUSD.nonces(user1);

        // 1. Get Domain Separator
        bytes32 domainSeparator = nectraUSD.DOMAIN_SEPARATOR();

        // 2. Calculate Permit Hash
        bytes32 permitHash = keccak256(abi.encode(PERMIT_TYPEHASH, user1, user2, approveAmount, nonce, deadline));

        // 3. Calculate EIP-712 Digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitHash));

        // 4. Sign Digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, digest);

        // 5. Call Permit
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);

        // 6. Check Allowance
        assertEq(nectraUSD.allowance(user1, user2), approveAmount, "Allowance not set correctly via permit");
        assertEq(nectraUSD.nonces(user1), nonce + 1, "Nonce not incremented");
    }

    function test_permit_revert_invalid_signature() public {
        uint256 approveAmount = 100 ether;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = (uint8(27), bytes32(0), bytes32(0)); // Invalid signature

        vm.expectRevert(ERC20.InvalidPermit.selector);
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);
    }

    function test_permit_revert_expired_deadline() public {
        uint256 approveAmount = 100 ether;
        uint256 deadline = vm.getBlockTimestamp() - 1 seconds; // Expired
        uint256 nonce = nectraUSD.nonces(user1);

        bytes32 domainSeparator = nectraUSD.DOMAIN_SEPARATOR();
        bytes32 permitHash = keccak256(abi.encode(PERMIT_TYPEHASH, user1, user2, approveAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, digest);

        vm.expectRevert(ERC20.PermitExpired.selector);
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);
    }

    function test_permit_revert_incorrect_nonce() public {
        uint256 approveAmount = 100 ether;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        uint256 incorrectNonce = nectraUSD.nonces(user1) + 1; // Incorrect nonce

        bytes32 domainSeparator = nectraUSD.DOMAIN_SEPARATOR();
        bytes32 permitHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, user1, user2, approveAmount, incorrectNonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, digest);

        vm.expectRevert(ERC20.InvalidPermit.selector); // Reverts due to nonce mismatch
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);
    }

    function test_permit_replay_attack() public {
        uint256 approveAmount = 100 ether;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        uint256 nonce = nectraUSD.nonces(user1);

        bytes32 domainSeparator = nectraUSD.DOMAIN_SEPARATOR();
        bytes32 permitHash = keccak256(abi.encode(PERMIT_TYPEHASH, user1, user2, approveAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, digest);

        // First call - should succeed
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);
        assertEq(nectraUSD.allowance(user1, user2), approveAmount, "Allowance not set on first call");
        assertEq(nectraUSD.nonces(user1), nonce + 1, "Nonce not incremented on first call");

        // Second call with same signature - should fail (invalid nonce)
        vm.expectRevert(ERC20.InvalidPermit.selector);
        nectraUSD.permit(user1, user2, approveAmount, deadline, v, r, s);
    }
}
