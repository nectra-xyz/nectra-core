// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @title NectraCoreStorage
/// @notice EIP-7201 namespaced storage for core protocol state
library NectraCoreStorage {
    // EIP-7201 namespaced slot. Do not change after deployment.
    bytes32 internal constant STORAGE_SLOT = keccak256("nectra.storage.core");

    struct Global {
        uint256 totalDebtShares;
        uint256 debt;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedLiquidatedDebtPerShare;
        uint256 unrealizedLiquidatedDebt;
    }

    struct Bucket {
        uint256 collateral;
        uint256 totalDebtShares;
        uint256 globalDebtShares;
        uint256 accumulatedLiquidatedCollateralPerShare;
        uint256 accumulatedRedeemedCollateralPerShare;
        uint256 lastGlobalAccumulatedLiquidatedCollateralPerShare;
        uint256 lastGlobalAccumulatedLiquidatedDebtPerShare;
        uint256 lastUpdateTime;
    }

    struct Position {
        uint256 interestRate;
        uint256 bucketEpoch;
        uint256 collateral;
        uint256 debtShares;
        uint256 lastBucketAccumulatedLiquidatedCollateralPerShare;
        uint256 lastBucketAccumulatedRedeemedCollateralPerShare;
    }

    struct Layout {
        bool flashMintLock;
        uint256 flashBorrowLock;

        Global _global;

        // interestRate => epoch => Bucket
        mapping(uint256 => mapping(uint256 => Bucket)) _buckets;
        // interestRate => epoch
        mapping(uint256 => uint256) _epochs;
        // positionId => Position
        mapping(uint256 => Position) _positions;
        // bitmask index => mask
        mapping(uint256 => uint256) _bucketBitMasks;

        // Redemption fee storage
        uint256 redemptionBuffer;
        uint256 redemptionLastUpdateTimestamp;

        // System variables
        uint256 numActiveBuckets;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}


