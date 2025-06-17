// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraBase} from "src/NectraBase.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployLocalTestNode is Script {
    address private _primaryFeed = 0x0f8393211778Eb4D894246459FE8f2A7F5973CBf;
    address private _secondaryFeed = 0x78f61463bE223028DedB3a93fF0C677179C2Ffc0;
    uint256 private _primaryStalenessPeriod = 24 hours;
    uint256 private _secondaryStalenessPeriod = 24 hours;

    address private savingsAccount = 0x76450AC480C71dcc30C467379427614f9D894f93;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:     ", deployer);
        console.log("Deployer bal: ", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);
        OracleAggregator oracleAggregator =
            new OracleAggregator(_primaryFeed, _secondaryFeed, _primaryStalenessPeriod, _secondaryStalenessPeriod);

        NUSDToken nectraUSD = new NUSDToken(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2));

        NectraNFT nectraNFT = new NectraNFT(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1));

        NectraBase.ConstructorArgs memory cargs = NectraBase.ConstructorArgs({
            nectraNFTAddress: address(nectraNFT),
            nusdTokenAddress: address(nectraUSD),
            oracleAddress: address(oracleAggregator),
            feeRecipientAddress: savingsAccount,
            minimumCollateral: 0, // 0 cBTC
            minimumDebt: 50 ether, // 50 nUSD
            maximumInterestRate: 1 ether, // 100%
            minimumInterestRate: 0.005 ether, // 0.5%
            interestRateIncrement: 0.0001 ether, // 0.01%
            liquidationRatio: 1.1 ether, // 110%
            liquidatorRewardPercentage: 0.9 ether, // 90%
            liquidationPenaltyPercentage: 0.15 ether, // 15%
            fullLiquidationRatio: 1.05 ether, // 105%
            fullLiquidationFee: 5 ether, // $5
            maximumLiquidatorReward: 5 ether, // $5
            issuanceRatio: 1.2 ether, // 120%
            redemptionFeeDecayPeriod: 6 hours, // 6 hours
            redemptionBaseFee: 0.005 ether, // 0.5%
            redemptionDynamicFeeScalar: 1, // 1
            redemptionFeeTreasuryThreshold: 0, // 0 -> Full fee to FEE_RECIPIENT
            openFeePercentage: 0.0015 ether, // 0.15%
            flashMintFee: 0.0025 ether, // 0.25%
            flashBorrowFee: 0.0025 ether // 0.25%
        });

        Nectra nectra = new Nectra(cargs);
        NectraExternal nectraExternal = new NectraExternal(address(nectra), address(nectraNFT));

        console.log("Nectra:           ", address(nectra));
        console.log("NectraUSD:        ", address(nectraUSD));
        console.log("NectraNFT:        ", address(nectraNFT));
        console.log("NectraExternal:   ", address(nectraExternal));
        console.log("OracleAggregator: ", address(oracleAggregator));
        vm.stopBroadcast();
    }
}
