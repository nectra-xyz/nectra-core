// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "src/interfaces/AggregatorV3Interface.sol";

interface IOracleAggregator {
    function primaryFeed() external view returns (AggregatorV3Interface);
    function secondaryFeed() external view returns (AggregatorV3Interface);
    function primaryDecimals() external view returns (uint8);
    function secondaryDecimals() external view returns (uint8);
    function primaryStalenessPeriod() external view returns (uint256);
    function secondaryStalenessPeriod() external view returns (uint256);
    function getLatestPrice() external view returns (uint256, bool);
}
