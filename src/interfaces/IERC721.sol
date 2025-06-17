// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IERC721 {
    error AccountBalanceOverflow();
    error BalanceQueryForZeroAddress();
    error NotOwnerNorApproved();
    error TokenAlreadyExists();
    error TokenDoesNotExist();
    error TransferFromIncorrectOwner();
    error TransferToNonERC721ReceiverImplementer();
    error TransferToZeroAddress();

    event Approval(address indexed owner, address indexed account, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool isApproved);
    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    function approve(address account, uint256 id) external payable;
    function balanceOf(address owner) external view returns (uint256 result);
    function getApproved(uint256 id) external view returns (address result);
    function isApprovedForAll(address owner, address operator) external view returns (bool result);
    function name() external view returns (string memory);
    function ownerOf(uint256 id) external view returns (address result);
    function safeTransferFrom(address from, address to, uint256 id) external payable;
    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) external payable;
    function setApprovalForAll(address operator, bool isApproved) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool result);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 id) external view returns (string memory);
    function transferFrom(address from, address to, uint256 id) external payable;
}
