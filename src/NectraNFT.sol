// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {ERC721} from "src/lib/ERC721.sol";

/// @title NectraNFT
/// @notice ERC721 token representing positions in the Nectra protocol
/// @dev Extends ERC721 with permission system and enumerable balance tracking
contract NectraNFT is ERC721 {
    enum Permission {
        Borrow,
        Withdraw,
        Repay,
        Deposit,
        AdjustInterest
    }

    error NotAuthorizedMinter();
    error NotOwner();
    error ERC721OutOfBoundsIndex(address owner, uint256 index);

    string internal constant NAME = "Nectra Position";
    string internal constant SYMBOL = "NTP";

    address internal immutable NECTRA_ADDRESS;

    uint256 internal _latestTokenId;

    mapping(uint256 => address[]) internal _authorized;
    mapping(uint256 => mapping(address => uint256)) internal _permissions;

    mapping(address owner => mapping(uint256 index => uint256)) private _ownedTokens;
    mapping(uint256 tokenId => uint256) private _ownedTokensIndex;
    mapping(uint256 tokenId => uint256) private _allTokensIndex;

    /// @param nectraAddress Address of the main Nectra contract
    constructor(address nectraAddress) {
        NECTRA_ADDRESS = nectraAddress;
    }

    /// @notice Returns the name of the token
    /// @return The token name
    function name() public view virtual override returns (string memory) {
        return NAME;
    }

    /// @notice Returns the symbol of the token
    /// @return The token symbol
    function symbol() public view virtual override returns (string memory) {
        return SYMBOL;
    }

    /// @notice Returns the URI for a given token ID
    /// @param id The token ID to query
    /// @return The token URI
    function tokenURI(uint256 id) public view virtual override returns (string memory) {}

    /// @notice Returns the total supply of tokens
    /// @return The total number of tokens minted
    function totalSupply() public view virtual returns (uint256) {
        return _latestTokenId;
    }

    /// @notice Returns the token ID at a given index of the tokens list of the requested owner
    /// @param owner The address to query
    /// @param index The index to query
    /// @return The token ID at the given index
    function tokenOfOwnerByIndex(address owner, uint256 index) public view virtual returns (uint256) {
        if (index > balanceOf(owner)) {
            revert ERC721OutOfBoundsIndex(owner, index);
        }
        return _ownedTokens[owner][index];
    }

    /// @notice Returns the token ID at a given index of all the tokens in this contract
    /// @param index The index to query
    /// @return The token ID at the given index
    function tokenByIndex(uint256 index) public view virtual returns (uint256) {
        if (index > totalSupply()) {
            revert ERC721OutOfBoundsIndex(address(0), index);
        }
        return index + 1;
    }

    /// @notice Mints a new position token
    /// @dev Only callable by the Nectra contract
    /// @param to The address that will own the minted token
    /// @return tokenId The ID of the newly minted token
    function mint(address to) external returns (uint256 tokenId) {
        require(msg.sender == NECTRA_ADDRESS, NotAuthorizedMinter());
        require(to != address(0), TransferToZeroAddress());

        tokenId = ++_latestTokenId;
        _mint(to, tokenId);

        return tokenId;
    }

    /// @notice Hook that is called before any token transfer
    /// @dev Revokes all permissions and updates token ownership tracking
    /// @param from The address which owns the token
    /// @param to The address which will receive the token
    /// @param id The ID of the token being transferred
    function _beforeTokenTransfer(address from, address to, uint256 id) internal override {
        _revokeAll(id);

        if (from != address(0) && balanceOf(from) > 0) {
            // To prevent a gap in from's tokens array, we store the last token
            // in the index of the token to delete, and then delete the
            // last slot (swap and pop).
            uint256 lastTokenIndex = balanceOf(from) - 1;
            uint256 tokenIndex = _ownedTokensIndex[id];

            mapping(uint256 index => uint256) storage _ownedTokensByOwner = _ownedTokens[from];

            // When the token to delete is the last token, the swap operation is unnecessary
            if (tokenIndex != lastTokenIndex) {
                uint256 lastTokenId = _ownedTokensByOwner[lastTokenIndex];

                // Move the last token to the slot of the to-delete token
                _ownedTokensByOwner[tokenIndex] = lastTokenId;
                // Update the moved token's index
                _ownedTokensIndex[lastTokenId] = tokenIndex;
            }

            // This also deletes the contents at the last position of the array
            delete _ownedTokensIndex[id];
            delete _ownedTokensByOwner[lastTokenIndex];
        }

        super._beforeTokenTransfer(from, to, id);
    }

    /// @notice Hook that is called after any token transfer
    /// @dev Updates token ownership tracking for the new owner
    /// @param to The address which will own the token
    /// @param id The ID of the token being transferred
    function _afterTokenTransfer(address, address to, uint256 id) internal override {
        uint256 length = balanceOf(to) - 1;
        _ownedTokens[to][length] = id;
        _ownedTokensIndex[id] = length;
    }

    /// @notice Grants a specific permission to an address for a token
    /// @param tokenId The ID of the token
    /// @param to The address to grant permission to
    /// @param permission The permission to grant
    function authorize(uint256 tokenId, address to, Permission permission) external {
        _requireOnlyOwner(tokenId);
        uint256 permissionMask = _permissions[tokenId][to];

        if (permissionMask == 0) {
            _authorized[tokenId].push(to);
        }

        _permissions[tokenId][to] = permissionMask | 1 << uint256(permission);
    }

    /// @notice Grants multiple permissions to an address for a token
    /// @param tokenId The ID of the token
    /// @param to The address to grant permissions to
    /// @param permissionsBitMask Bit mask of permissions to grant
    function authorize(uint256 tokenId, address to, uint256 permissionsBitMask) external {
        _requireOnlyOwner(tokenId);
        uint256 permissionMask = _permissions[tokenId][to];

        if (permissionMask == 0 && permissionsBitMask > 0) {
            // Only add to the authorized list if there is at least one permission being granted
            // This prevents adding an empty address to the list
            // which would otherwise happen if permissionsBitMask is 0
            _authorized[tokenId].push(to);
        } else if (permissionMask > 0 && permissionsBitMask == 0) {
            // If permissionsBitMask is 0, we are revoking all permissions
            // so we should remove the address from the authorized list
            uint256 length = _authorized[tokenId].length;
            for (uint256 i = 0; i < length; i++) {
                if (_authorized[tokenId][i] == to) {
                    _authorized[tokenId][i] = _authorized[tokenId][length - 1];
                    _authorized[tokenId].pop();
                    break;
                }
            }
        }

        // Update the permissions for the address
        _permissions[tokenId][to] = permissionsBitMask;
    }

    /// @notice Revokes a specific permission from an address for a token
    /// @param tokenId The ID of the token
    /// @param operator The address to revoke permission from
    /// @param permission The permission to revoke
    function revoke(uint256 tokenId, address operator, Permission permission) external {
        _requireOnlyOwner(tokenId);

        if (_permissions[tokenId][operator] != 0) {
            _permissions[tokenId][operator] &= ~(1 << uint256(permission));

            if (_permissions[tokenId][operator] == 0) {
                uint256 length = _authorized[tokenId].length;
                for (uint256 i = 0; i < length; i++) {
                    if (_authorized[tokenId][i] == operator) {
                        _authorized[tokenId][i] = _authorized[tokenId][length - 1];
                        _authorized[tokenId].pop();
                        break;
                    }
                }
            }
        }
    }

    /// @notice Revokes all permissions for a token
    /// @param tokenId The ID of the token
    function revokeAll(uint256 tokenId) external {
        _requireOnlyOwner(tokenId);

        _revokeAll(tokenId);
    }

    /// @notice Internal function to revoke all permissions for a token
    /// @param tokenId The ID of the token
    function _revokeAll(uint256 tokenId) internal {
        for (uint256 i = 0; i < _authorized[tokenId].length; i++) {
            address operator = _authorized[tokenId][i];
            delete _permissions[tokenId][operator];
        }

        delete _authorized[tokenId];
    }

    /// @notice Checks if an address has a specific permission for a token
    /// @param tokenId The ID of the token
    /// @param operator The address to check
    /// @param permission The permission to check
    /// @return True if the address has the permission
    function authorized(uint256 tokenId, address operator, Permission permission) external view returns (bool) {
        return ownerOf(tokenId) == operator || _permissions[tokenId][operator] & (1 << uint256(permission)) > 0;
    }

    /// @notice Checks if an address has multiple permissions for a token
    /// @param tokenId The ID of the token
    /// @param operator The address to check
    /// @param permissionsBitMask Bit mask of permissions to check
    /// @return True if the address has all the specified permissions
    function authorized(uint256 tokenId, address operator, uint256 permissionsBitMask) external view returns (bool) {
        return ownerOf(tokenId) == operator
            || (permissionsBitMask > 0 && _permissions[tokenId][operator] & permissionsBitMask == permissionsBitMask);
    }

    /// @notice Internal function to check if the caller is the owner of a token
    /// @param tokenId The ID of the token
    function _requireOnlyOwner(uint256 tokenId) internal view {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
    }

    /// @notice Returns all token IDs owned by an address
    /// @param owner The address to query
    /// @return Array of token IDs owned by the address
    function getTokenIdsForAddress(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = _ownedTokens[owner][i];
        }
        return tokenIds;
    }
}
