// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface INectraNFT {
    type Permission is uint8;

    error AccountBalanceOverflow();
    error BalanceQueryForZeroAddress();
    error NotAuthorizedMinter();
    error NotOwner();
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
    function authorize(uint256 tokenId, address to, Permission permission) external;
    function authorize(uint256 tokenId, address to, uint256 permissionsBitMask) external;
    function authorized(uint256 tokenId, address operator, Permission permission) external view returns (bool);
    function authorized(uint256 tokenId, address operator, uint256 permissionsBitMask) external view returns (bool);
    function balanceOf(address owner) external view returns (uint256 result);
    function getApproved(uint256 id) external view returns (address result);
    function isApprovedForAll(address owner, address operator) external view returns (bool result);
    function mint(address to) external returns (uint256 tokenId);
    function name() external view returns (string memory);
    function ownerOf(uint256 id) external view returns (address result);
    function revoke(uint256 tokenId, address operator, Permission permission) external;
    function revokeAll(uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 id) external payable;
    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) external payable;
    function setApprovalForAll(address operator, bool isApproved) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool result);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 id) external view returns (string memory);
    function transferFrom(address from, address to, uint256 id) external payable;
    function getTokenIdsForAddress(address owner) external view returns (uint256[] memory);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function tokenByIndex(uint256 index) external view returns (uint256);
}
