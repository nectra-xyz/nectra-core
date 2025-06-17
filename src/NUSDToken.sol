// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {ERC20} from "src/lib/ERC20.sol";

/// @title NUSDToken
/// @notice ERC20 token representing the Nectra USD stablecoin
/// @dev Extends ERC20 with minting and burning capabilities restricted to the Nectra contract
contract NUSDToken is ERC20 {
    string internal constant NAME = "Nectra USD";
    string internal constant SYMBOL = "NUSD";

    address internal immutable MINTER;

    error NotMinter();

    /// @param minter Address of the contract that can mint and burn tokens
    constructor(address minter) {
        MINTER = minter;
    }

    /// @notice Returns the name of the token
    /// @return The token name
    function name() public pure override returns (string memory) {
        return NAME;
    }

    /// @notice Returns the symbol of the token
    /// @return The token symbol
    function symbol() public pure override returns (string memory) {
        return SYMBOL;
    }

    /// @notice Mints new tokens to a specified address
    /// @dev Only callable by the minter contract
    /// @param to The address that will receive the minted tokens
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, NotMinter());
        _mint(to, amount);
    }

    /// @notice Burns tokens from a specified address
    /// @dev Only callable by the minter contract. Spends allowance if the caller is not the token owner
    /// @param from The address whose tokens will be burned
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external {
        require(msg.sender == MINTER, NotMinter());
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    /// @notice Approves spending of tokens via signature
    /// @dev Implements EIP-2612 permit functionality
    /// @param owner The address that owns the tokens
    /// @param spender The address that will be approved to spend
    /// @param value The amount of tokens to approve
    /// @param deadline The timestamp after which the permit is no longer valid
    /// @param v The recovery byte of the signature
    /// @param r The first 32 bytes of the signature
    /// @param s The last 32 bytes of the signature
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        override
    {
        super.permit(owner, spender, value, deadline, v, r, s);
    }
}
