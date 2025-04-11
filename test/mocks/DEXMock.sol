// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract DEXMock is Test {
    uint256 public constant UNIT = 1 ether;

    NUSDToken public nUSD;
    address public owner;
    OracleAggregator public oracle;
    uint256 public slippageAndFees;

    constructor(address _nectraUSD, address _nectra, address _oracle) {
        nUSD = NUSDToken(_nectraUSD);
        owner = _nectra;
        oracle = OracleAggregator(_oracle);
    }
    // Mock DEX contract that allows buying and selling cBTC for nUSD

    function buyBTC(uint256 amount) external returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");

        (uint256 price,) = oracle.getLatestPrice();
        uint256 nUSDAmount = amount * price / UNIT;

        // Apply slippage and fees on nUSD used to pay
        // function behaves as exactOut
        if (slippageAndFees > 0) {
            nUSDAmount = nUSDAmount * (UNIT + slippageAndFees) / UNIT;
        }

        nUSD.transferFrom(msg.sender, address(this), nUSDAmount);
        nUSD.approve(owner, nUSDAmount);

        vm.prank(owner);
        nUSD.burn(address(this), nUSDAmount);

        payable(msg.sender).transfer(amount);

        return amount;
    }

    function sellBTC(uint256 amount) external payable returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        require(msg.value == amount, "Insufficient cBTC sent");

        (uint256 price,) = oracle.getLatestPrice();
        uint256 nUSDAmount = amount * price / UNIT;

        // Apply slippage and fees on nUSD received
        // function behaves as exactIn
        if (slippageAndFees > 0) {
            nUSDAmount = nUSDAmount * (UNIT - slippageAndFees) / UNIT;
        }

        vm.prank(owner);
        nUSD.mint(msg.sender, nUSDAmount);

        return nUSDAmount;
    }

    function setSlippageAndFees(uint256 _slippageAndFees) external {
        slippageAndFees = _slippageAndFees;
    }
}
