// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {NectraBase} from "src/NectraBase.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";

import {ERC1967Proxy} from "src/lib/ERC1967Proxy.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployTestnet is Script {
    address private _primaryFeed = 0x0f8393211778Eb4D894246459FE8f2A7F5973CBf;
    address private _secondaryFeed = 0x78f61463bE223028DedB3a93fF0C677179C2Ffc0;
    uint256 private _primaryStalenessPeriod = 24 hours;
    uint256 private _secondaryStalenessPeriod = 24 hours;

    address private savingsAccount = 0x39774D75851FAD404b3d35b4cC8724171Cf86879;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("NECTRA_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:     ", deployer);
        console.log("Deployer bal: ", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);
        // OracleAggregator oracleAggregator =
        //     new OracleAggregator(_primaryFeed, _secondaryFeed, _primaryStalenessPeriod, _secondaryStalenessPeriod);
        OracleAggregator oracleAggregator = OracleAggregator(0x4c9aC40e2ee46eDD1626EF835F926D5a68182056);

        // deploy nectra with the initial implementation to get an address for core
        Nectra nectraImplementation = new Nectra();
        ERC1967Proxy nectraProxy = new ERC1967Proxy(
            address(nectraImplementation),
            bytes("") // no initializer data
        );
        Nectra nectra = Nectra(address(nectraProxy));

        // deploy nft
        NectraNFT nectraNFTImplementation = new NectraNFT();
        ERC1967Proxy nftProxy = new ERC1967Proxy(
            address(nectraNFTImplementation),
            abi.encodeWithSelector(
                NectraNFT.initialize.selector,
                deployer, // owner
                address(nectra) // minter
            )
        );
        NectraNFT nectraNFT = NectraNFT(address(nftProxy));

        // deploy nUSD
        NUSDToken nectraUSDImplementation = new NUSDToken();
        ERC1967Proxy nusdProxy = new ERC1967Proxy(
            address(nectraUSDImplementation),
            abi.encodeWithSelector(
                NUSDToken.initialize.selector,
                deployer, // owner
                address(nectra) // minter
            )
        );
        NUSDToken nectraUSD = NUSDToken(address(nusdProxy));

        NectraBase.SystemParams memory params = NectraBase.SystemParams({
            nectraNFTAddress: address(nectraNFT),
            nusdTokenAddress: address(nectraUSD),
            oracleAddress: address(oracleAggregator),
            feeRecipientAddress: savingsAccount,
            minimumCollateral: 0, // 0 cBTC
            minimumDebt: 50 ether, // 50 nUSD
            systemInterestRate: 0.025 ether, // 2.5%
            maximumInterestRate: 1 ether, // 100%
            minimumInterestRate: 0 ether, // 0%
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
            redemptionDynamicFeeScalar: 1 ether, // 1
            redemptionFeeTreasuryThreshold: 0, // 0 -> Full fee to FEE_RECIPIENT
            openFeePercentage: 0.0015 ether, // 0.15%
            flashMintFee: 0.0025 ether, // 0.25%
            flashBorrowFee: 0.0025 ether // 0.25%
        });
        nectra.initialize(params);

        NectraExternal nectraExternal = new NectraExternal(address(nectra), address(nectraNFT));

        console.log("Nectra:           ", address(nectra));
        console.log("NectraUSD:        ", address(nectraUSD));
        console.log("NectraNFT:        ", address(nectraNFT));
        console.log("NectraExternal:   ", address(nectraExternal));
        console.log("OracleAggregator: ", address(oracleAggregator));
        vm.stopBroadcast();
    }
}
