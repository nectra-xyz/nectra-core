// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "src/lib/FixedPointMathLib.sol";
import {SafeCastLib} from "src/lib/SafeCastLib.sol";

/// @title NectraMathLib
/// @notice Core mathematical operations for the Nectra protocol
/// @dev Provides safe math operations for shares/assets conversion and bit manipulation
library NectraMathLib {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    /// @notice Thrown when a mathematical operation results in an overflow
    error Overflow();

    /// @notice Rounding modes for mathematical operations
    /// @param Down Round down to the nearest value
    /// @param Up Round up to the nearest value
    enum Rounding {
        Down,
        Up
    }

    /// @notice Converts shares to assets using the given ratio
    /// @dev Uses safe math operations to prevent overflow
    /// @param shares Amount of shares to convert
    /// @param totalAssets Total assets in the system
    /// @param totalShares Total shares in the system
    /// @param rounding Rounding mode to use
    /// @return Amount of assets equivalent to the shares
    function convertToAssets(uint256 shares, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return mulDiv(shares, totalAssets + 1, totalShares + 1, rounding);
    }

    /// @notice Converts assets to shares using the given ratio
    /// @dev Uses safe math operations to prevent overflow
    /// @param assets Amount of assets to convert
    /// @param totalAssets Total assets in the system
    /// @param totalShares Total shares in the system
    /// @param rounding Rounding mode to use
    /// @return Amount of shares equivalent to the assets
    function convertToShares(uint256 assets, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return mulDiv(assets, totalShares + 1, totalAssets + 1, rounding);
    }

    /// @notice Converts signed shares to signed assets using the given ratio
    /// @dev Handles negative values and uses safe math operations
    /// @param shares Amount of shares to convert (can be negative)
    /// @param totalAssets Total assets in the system
    /// @param totalShares Total shares in the system
    /// @param rounding Rounding mode to use
    /// @return Amount of assets equivalent to the shares (can be negative)
    function convertToAssets(int256 shares, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (int256)
    {
        uint256 sharesAbs = shares < 0 ? uint256(-shares) : uint256(shares);
        uint256 assets = convertToAssets(sharesAbs, totalAssets, totalShares, rounding);
        return shares > 0 ? int256(assets) : -int256(assets);
    }

    /// @notice Converts signed assets to signed shares using the given ratio
    /// @dev Handles negative values and uses safe math operations
    /// @param assets Amount of assets to convert (can be negative)
    /// @param totalAssets Total assets in the system
    /// @param totalShares Total shares in the system
    /// @param rounding Rounding mode to use
    /// @return Amount of shares equivalent to the assets (can be negative)
    function convertToShares(int256 assets, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (int256)
    {
        uint256 assetsAbs = assets < 0 ? uint256(-assets) : uint256(assets);
        uint256 shares = convertToShares(assetsAbs, totalAssets, totalShares, rounding);
        return assets > 0 ? int256(shares) : -int256(shares);
    }

    /// @notice Performs saturating addition between a uint256 and an int256
    /// @dev Returns 0 if the result would be negative
    /// @param a First operand (unsigned)
    /// @param b Second operand (signed)
    /// @return Result of the addition, saturated at 0
    function saturatingAdd(uint256 a, int256 b) internal pure returns (uint256) {
        int256 res = (a.toInt256() + b);
        if (res < 0) res = 0;
        return res.toUint256();
    }

    /// @notice Performs multiplication and division with specified rounding
    /// @dev Uses FixedPointMathLib for safe operations
    /// @param x First operand
    /// @param y Second operand
    /// @param denominator Divisor
    /// @param rounding Rounding mode to use
    /// @return Result of the operation
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) private pure returns (uint256) {
        return rounding == Rounding.Down ? x.mulDiv(y, denominator) : x.mulDivUp(y, denominator);
    }

    /// @notice Finds the position of the first set bit in a number
    /// @dev Uses a binary bit search
    /// @param x The number to find the first set bit in
    /// @return pos Position of the first set bit (0-based)
    function findFirstSet(uint256 x) internal pure returns (uint256 pos) {
        assembly {
            // Check if lower 128 bits are zero
            if iszero(and(x, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)) {
                x := shr(128, x)
                pos := add(pos, 128)
            }

            // Check if lower 64 bits are zero
            if iszero(and(x, 0xFFFFFFFFFFFFFFFF)) {
                x := shr(64, x)
                pos := add(pos, 64)
            }

            // Check if lower 32 bits are zero
            if iszero(and(x, 0xFFFFFFFF)) {
                x := shr(32, x)
                pos := add(pos, 32)
            }

            // Check if lower 16 bits are zero
            if iszero(and(x, 0xFFFF)) {
                x := shr(16, x)
                pos := add(pos, 16)
            }

            // Check if lower 8 bits are zero
            if iszero(and(x, 0xFF)) {
                x := shr(8, x)
                pos := add(pos, 8)
            }

            // Check if lower 4 bits are zero
            if iszero(and(x, 0xF)) {
                x := shr(4, x)
                pos := add(pos, 4)
            }

            // Check if lower 2 bits are zero
            if iszero(and(x, 0x3)) {
                x := shr(2, x)
                pos := add(pos, 2)
            }

            // Check if lowest bit is zero
            if iszero(and(x, 0x1)) { pos := add(pos, 1) }
        }
        return pos;
    }
}
