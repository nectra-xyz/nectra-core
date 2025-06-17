// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Nectra} from "src/Nectra.sol";
import {NUSDToken} from "src/NUSDToken.sol";

contract LiquidatePartialReentrancy {
    Nectra public nectra;

    uint256 public tokenId;

    constructor(Nectra _nectra) {
        nectra = _nectra;
    }

    function liquidate(uint256 _tokenId) external {
        tokenId = _tokenId;

        nectra.liquidate(_tokenId);
    }

    receive() external payable {
        nectra.liquidate(tokenId);
    }
}
