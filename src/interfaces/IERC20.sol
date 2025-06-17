// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IERC20 {
    error AllowanceOverflow();
    error AllowanceUnderflow();
    error InsufficientAllowance();
    error InsufficientBalance();
    error InvalidPermit();
    error Permit2AllowanceIsFixedAtInfinity();
    error PermitExpired();
    error TotalSupplyOverflow();

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function DOMAIN_SEPARATOR() external view returns (bytes32 result);
    function allowance(address owner, address spender) external view returns (uint256 result);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256 result);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function nonces(address owner) external view returns (uint256 result);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256 result);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
