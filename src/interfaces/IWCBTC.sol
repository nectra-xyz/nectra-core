// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "src/interfaces/IERC20.sol";

interface IWCBTC is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
