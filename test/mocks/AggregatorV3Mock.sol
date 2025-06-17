// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "src/interfaces/AggregatorV3Interface.sol";

contract AggregatorV3Mock is AggregatorV3Interface {
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint8 internal _decimals;
    bool internal _callShouldRevert;

    constructor(uint256 initialAnswer, uint256 initialUpdatedAt, uint8 initialDecimals) {
        _answer = int256(initialAnswer);
        _updatedAt = initialUpdatedAt;
        _decimals = initialDecimals;
        _callShouldRevert = false;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {}

    function version() external view override returns (uint256) {}

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = _roundId;
        answer = _answer;
        startedAt = 0;
        updatedAt = _updatedAt;
        answeredInRound = 0;
        revert("Not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (_callShouldRevert) {
            revert("Oracle Test Revert");
        }
        return (0, _answer, 0, _updatedAt, 0);
    }

    function setLatestAnswer(int256 answer) external {
        _answer = answer;
    }

    function setLatestTimestamp(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setCallShouldRevert(bool shouldRevert) external {
        _callShouldRevert = shouldRevert;
    }
}
