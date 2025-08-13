// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "src/lib/ERC20.sol";

contract WCBTCMock is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped Citrea Bitcoin";
    }

    function symbol() public pure override returns (string memory) {
        return "WCBTC";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    // Allow the contract to receive ETH
    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}