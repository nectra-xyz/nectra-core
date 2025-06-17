// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract OracleAggregatorMock {
    uint256 public price;
    bool public isStale;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function getLatestPrice() external view returns (uint256, bool) {
        return (price, isStale);
    }

    function setCurrentPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function setStale(bool stale) external {
        isStale = stale;
    }
}
