// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract InitialImplementation is UUPSUpgradeable {
    function initialize() public  {}

    /// @notice Authorizes the upgrade of the implementation contract
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override {}
}