// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SatsumaHandler} from "src/auxiliary/SatsumaHandler.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {NectraFlashHandler} from "src/auxiliary/NectraFlashHandler.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployFlashHandlerTestnet is Script {
    uint256 deployerPrivateKey = vm.envUint("NECTRA_DEPLOYER_PRIVATE_KEY");
    address public deployer = vm.addr(deployerPrivateKey);

    // Nectra Deployment
    address public nUSD = 0x9B28B690550522608890C3C7e63c0b4A7eBab9AA;
    address public nectra = 0x6cDC594d5A135d0307aee3449023A42385422355;
    address public nectraNFT = 0xcfb6737893A18D10936bc622BCe04fc7f50776a0;
    address public oracleAggregator = 0x4c9aC40e2ee46eDD1626EF835F926D5a68182056;

    // Satsuma Deployment
    address public swapRouter = 0x3012E9049d05B4B5369D690114D5A5861EbB85cb;
    address public quoter = 0xa77aD9f635a3FB3bCCC5E6d1A87cB269746Aba17;
    address public WCBTC = 0x8d0c9d1c17aE5e40ffF9bE350f57840E9E66Cd93;

    NectraExternal public nectraExternal;
    SatsumaHandler public satsumaHandler;
    NectraFlashHandler public nectraFlashHandler;

    function run() public {
        vm.startBroadcast(deployerPrivateKey);
        console.log("Deployer:     ", deployer);

        // Deploy new NectraExternal
        // nectraExternal = new NectraExternal(nectra, nectraNFT);
        // TODO: Change to the actual address
        nectraExternal = NectraExternal(0x0000000000000000000000000000000000000000);

        // Deploy the SatsumaDex Handler
        satsumaHandler = new SatsumaHandler(swapRouter, quoter, nUSD, WCBTC);

        // Deploy NectraFlashHandler
        nectraFlashHandler = new NectraFlashHandler(
            nUSD, nectra, nectraNFT, address(nectraExternal), oracleAggregator, payable(satsumaHandler)
        );

        console.log("NectraExternal: ", address(nectraExternal));
        console.log("SatsumaHandler: ", address(satsumaHandler));
        console.log("NectraFlashHandler: ", address(nectraFlashHandler));

        console.log("\n  Deployer cBTC bal: ", deployer.balance);
        vm.stopBroadcast();
    }
}
