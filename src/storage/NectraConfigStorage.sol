// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @title NectraConfigStorage
/// @notice EIP-7201 namespaced storage for immutable-like protocol configuration
library NectraConfigStorage {
    // EIP-7201 namespaced slot. Do not change after deployment.
    bytes32 internal constant STORAGE_SLOT = keccak256("nectra.storage.config");

    struct Layout {
        // Risk params
        uint256 LIQUIDATION_RATIO;
        uint256 FULL_LIQUIDATION_RATIO;
        uint256 ISSUANCE_RATIO;

        // Liquidation params
        uint256 LIQUIDATION_PENALTY_PERCENTAGE;
        uint256 LIQUIDATOR_REWARD_PERCENTAGE;
        uint256 MAX_LIQUIDATOR_REWARD;
        uint256 FULL_LIQUIDATOR_FEE;

        // Redemption fee params
        uint256 REDEMPTION_FEE_DECAY_PERIOD;
        uint256 REDEMPTION_BASE_FEE;
        uint256 REDEMPTION_DYNAMIC_FEE_SCALAR;
        uint256 REDEMPTION_FEE_TREASURY_THRESHOLD;

        // Interest grid params
        uint256 SYSTEM_INTEREST_RATE;
        uint256 MAXIMUM_INTEREST_RATE;
        uint256 MINIMUM_INTEREST_RATE;
        uint256 INTEREST_RATE_INCREMENT;

        // Fees
        uint256 OPEN_FEE_PERCENTAGE;
        uint256 FLASH_MINT_FEE;
        uint256 FLASH_BORROW_FEE;

        // Minimums
        uint256 MINIMUM_COLLATERAL;
        uint256 MINIMUM_BORROW;

        // Addresses
        address NECTRA_NFT_ADDRESS;
        address NUSD_TOKEN_ADDRESS;
        address ORACLE_ADDRESS;
        address FEE_RECIPIENT_ADDRESS;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}


