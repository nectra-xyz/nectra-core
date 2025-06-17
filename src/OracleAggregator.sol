// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

/// @title OracleAggregator
/// @notice Aggregates prices from two Chainlink oracles and provides the most recent valid price.
/// @dev Falls back to a secondary oracle if the primary one is stale or returns an invalid result.
contract OracleAggregator {
    /// @notice Address of the primary Chainlink aggregator.
    AggregatorV3Interface public immutable primaryFeed;

    /// @notice Address of the secondary Chainlink aggregator.
    AggregatorV3Interface public immutable secondaryFeed;

    /// @notice Number of decimals used by the primary feed.
    uint8 public immutable primaryDecimals;

    /// @notice Number of decimals used by the secondary feed.
    uint8 public immutable secondaryDecimals;

    /// @notice Maximum allowed staleness (in seconds) for primary oracle responses.
    uint256 public immutable primaryStalenessPeriod;

    /// @notice Maximum allowed staleness (in seconds) for secondary oracle responses.
    uint256 public immutable secondaryStalenessPeriod;

    /// @param _primaryFeed Address of the primary Chainlink aggregator.
    /// @param _secondaryFeed Address of the secondary Chainlink aggregator.
    /// @param _primaryStalenessPeriod Max age for primary price data in seconds.
    /// @param _secondaryStalenessPeriod Max age for secondary price data in seconds.
    constructor(
        address _primaryFeed,
        address _secondaryFeed,
        uint256 _primaryStalenessPeriod,
        uint256 _secondaryStalenessPeriod
    ) {
        require(_primaryFeed != address(0) && _secondaryFeed != address(0), "Invalid feed address");

        primaryFeed = AggregatorV3Interface(_primaryFeed);
        secondaryFeed = AggregatorV3Interface(_secondaryFeed);

        primaryDecimals = primaryFeed.decimals();
        secondaryDecimals = secondaryFeed.decimals();

        primaryStalenessPeriod = _primaryStalenessPeriod;
        secondaryStalenessPeriod = _secondaryStalenessPeriod;
    }

    /// @notice Returns the most recent valid price from the oracles.
    /// @dev Attempts the primary feed first, and falls back to the secondary if the primary is stale or invalid.
    /// @return price Normalized price to 18 decimals.
    /// @return invalid True if both feeds are invalid or stale.
    function getLatestPrice() external view returns (uint256, bool) {
        uint256 primaryPrice;
        bool invalid;

        (primaryPrice, invalid) = _tryGetPrice(primaryFeed, primaryDecimals, primaryStalenessPeriod);
        if (!invalid) return (primaryPrice, false);

        uint256 secondaryPrice;
        (secondaryPrice, invalid) = _tryGetPrice(secondaryFeed, secondaryDecimals, secondaryStalenessPeriod);
        if (!invalid) return (secondaryPrice, false);

        // Return the best available price if both feeds are stale or invalid
        return (primaryPrice > 0 ? primaryPrice : secondaryPrice, true);
    }

    /// @notice Attempts to fetch a normalized price from a feed with staleness check.
    /// @dev Uses staticcall and decodes raw response from the Chainlink oracle.
    /// @param feed Oracle feed interface.
    /// @param decimals Number of decimals for the given feed.
    /// @param stalenessPeriod Max allowed age in seconds before the feed is considered stale.
    /// @return price Normalized price.
    /// @return isStale True if the price is invalid or stale.
    function _tryGetPrice(AggregatorV3Interface feed, uint8 decimals, uint256 stalenessPeriod)
        internal
        view
        returns (uint256 price, bool isStale)
    {
        (bool success, bytes memory result) =
            address(feed).staticcall(abi.encodeWithSelector(feed.latestRoundData.selector));

        if (!success) return (0, true);

        (, int256 rawAnswer,, uint256 updatedAt,) = abi.decode(result, (uint80, int256, uint256, uint256, uint80));

        if (rawAnswer <= 0 || updatedAt > block.timestamp) return (0, true);

        price = _normalize(uint256(rawAnswer), decimals);
        isStale = block.timestamp > updatedAt + stalenessPeriod;
    }

    /// @notice Normalizes oracle output to 18 decimals.
    /// @param value The raw value from the feed.
    /// @param decimals The number of decimals the raw value has.
    /// @return The value normalized to 18 decimals.
    function _normalize(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals > 18) return value / (10 ** (decimals - 18));
        return value * (10 ** (18 - decimals));
    }
}
