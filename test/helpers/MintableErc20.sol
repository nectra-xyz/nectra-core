// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "src/lib/ERC20.sol";

contract MintableErc20 is ERC20 {
    string private  _name;
    string private  _symbol;
    uint8 private _decimals;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }


    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
