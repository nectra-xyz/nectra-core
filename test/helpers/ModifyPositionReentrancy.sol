// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Nectra} from "src/Nectra.sol";
import {NUSDToken} from "src/NUSDToken.sol";

contract ModifyPositionReentrancy {
    Nectra public nectra;
    NUSDToken public nectraUSD;

    uint256 public tokenId;
    uint256 public collateral;
    uint256 public debt;
    uint256 public interestRate;

    constructor(Nectra _nectra, NUSDToken _nectraUSD) {
        nectra = _nectra;
        nectraUSD = _nectraUSD;
    }

    function modifyPosition(
        uint256 _tokenId,
        uint256 _collateral,
        uint256 _debt,
        uint256 _interestRate,
        uint256 _debtDiff
    ) external {
        tokenId = _tokenId;
        collateral = _collateral;
        debt = _debt;
        interestRate = _interestRate;

        nectraUSD.approve(address(nectra), _debtDiff);

        // Pay off debt some debt and withdraw some collateral to trigger reentrancy.
        nectra.modifyPosition(_tokenId, -1 ether, -int256(_debtDiff / 2), _interestRate, "");
    }

    receive() external payable {
        // Re-enter modifyPosition attempt to withdraw full collateral amount, this should
        // still succeed because the withdraw amount is capped to what is available in the position.
        nectra.modifyPosition(tokenId, -int256(collateral), -int256(debt / 2), interestRate, "");
    }
}
