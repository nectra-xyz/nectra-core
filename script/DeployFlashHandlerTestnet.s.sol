// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SatsumaHandler} from "src/auxiliary/SatsumaHandler.sol";
import {NectraFlashHandler} from "src/auxiliary/NectraFlashHandler.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployFlashHandlerTestnet is Script {
    uint256 deployerPrivateKey = vm.envUint("NECTRA_DEPLOYER_PRIVATE_KEY");
    address public deployer = vm.addr(deployerPrivateKey);

    // Nectra Deployment
    address public nUSD = 0x0Fe56deAdC50e29441063dF84226346a99220118;
    address public nectra = 0x1EC6A6A7c3f132a08E3e708bDb6623D26Cb35d3d;
    address public nectraNFT = 0x83b196CDb9464870EbA5AdE7769fF66Ac38F0C30;
    address public nectraExternal = 0x5a0c0344Fe1A92342d0e88207ED29bF2369b82E0;
    address public oracleAggregator = 0x4c9aC40e2ee46eDD1626EF835F926D5a68182056;

    // Satsuma Deployment
    address public swapRouter = 0x3012E9049d05B4B5369D690114D5A5861EbB85cb;
    address public quoter = 0xa77aD9f635a3FB3bCCC5E6d1A87cB269746Aba17;
    address public WCBTC = 0x8d0c9d1c17aE5e40ffF9bE350f57840E9E66Cd93;

    SatsumaHandler public satsumaHandler;
    NectraFlashHandler public nectraFlashHandler;

    function run() public {
        vm.startBroadcast(deployerPrivateKey);
        console.log("Deployer:     ", deployer);

        // Deploy the SatsumaDex Handler
        satsumaHandler = new SatsumaHandler(swapRouter, quoter, nUSD, WCBTC);

        // Deploy NectraFlashHandler
        nectraFlashHandler =
            new NectraFlashHandler(nUSD, nectra, nectraNFT, nectraExternal, oracleAggregator, payable(satsumaHandler));

        console.log("SatsumaHandler: ", address(satsumaHandler));
        console.log("NectraFlashHandler: ", address(nectraFlashHandler));

        console.log("\n  Deployer cBTC bal: ", deployer.balance);
        vm.stopBroadcast();
    }
}
