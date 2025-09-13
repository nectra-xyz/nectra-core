// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {NectraBaseTest} from "test/NectraBase.t.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";

contract NectraStorageTest is NectraBaseTest {
    function setUp() public override {
        // Tune fees to non-zero so redemption fee dynamics can be observed
        systemParams.redemptionDynamicFeeScalar = 0.1 ether; // > 0
        systemParams.redemptionBaseFee = 0.01 ether; // 1%
        super.setUp();
    }

    function test_Config_ValuesStoredCorrectly() public view {
        NectraBase.SystemParams memory cfg = nectra.getConfig();
        assertEq(cfg.nectraNFTAddress, address(nectraNFT), "NECTRA_NFT_ADDRESS");
        assertEq(cfg.nusdTokenAddress, address(nectraUSD), "NUSD_TOKEN_ADDRESS");
        assertEq(cfg.oracleAddress, address(oracle), "ORACLE_ADDRESS");
        assertEq(cfg.feeRecipientAddress, feeRecipient, "FEE_RECIPIENT_ADDRESS");

        assertEq(cfg.minimumCollateral, systemParams.minimumCollateral, "MINIMUM_COLLATERAL");
        assertEq(cfg.minimumDebt, systemParams.minimumDebt, "MINIMUM_BORROW");
        assertEq(cfg.maximumInterestRate, systemParams.maximumInterestRate, "MAX_RATE");
        assertEq(cfg.minimumInterestRate, systemParams.minimumInterestRate, "MIN_RATE");
        assertEq(cfg.interestRateIncrement, systemParams.interestRateIncrement, "RATE_INCREMENT");
        assertEq(cfg.liquidationRatio, systemParams.liquidationRatio, "LIQ_RATIO");
        assertEq(cfg.fullLiquidationRatio, systemParams.fullLiquidationRatio, "FULL_LIQ_RATIO");
        assertEq(cfg.issuanceRatio, systemParams.issuanceRatio, "ISSUANCE_RATIO");
        assertEq(cfg.liquidationPenaltyPercentage, systemParams.liquidationPenaltyPercentage, "LIQ_PENALTY");
        assertEq(cfg.liquidatorRewardPercentage, systemParams.liquidatorRewardPercentage, "LIQ_REWARD_PCT");
        assertEq(cfg.maximumLiquidatorReward, systemParams.maximumLiquidatorReward, "MAX_LIQ_REWARD");
        assertEq(cfg.openFeePercentage, systemParams.openFeePercentage, "OPEN_FEE");
        assertEq(cfg.flashMintFee, systemParams.flashMintFee, "FLASH_MINT_FEE");
        assertEq(cfg.flashBorrowFee, systemParams.flashBorrowFee, "FLASH_BORROW_FEE");
        assertEq(cfg.redemptionFeeDecayPeriod, systemParams.redemptionFeeDecayPeriod, "REDEEM_DECAY");
        assertEq(cfg.redemptionBaseFee, systemParams.redemptionBaseFee, "REDEEM_BASE");
        assertEq(cfg.redemptionDynamicFeeScalar, systemParams.redemptionDynamicFeeScalar, "REDEEM_SCALAR");
        assertEq(cfg.redemptionFeeTreasuryThreshold, systemParams.redemptionFeeTreasuryThreshold, "REDEEM_TREASURY_TH");
    }

    function test_CoreNamespace_RedemptionFeeBufferPersists() public {
        // Open a position and borrow so that we can redeem
        uint256 minRate = systemParams.minimumInterestRate;
        vm.deal(address(this), address(this).balance + 2 ether);
        (uint256 tokenId,, , ,) = nectra.modifyPosition{value: 2 ether}(0, int256(2 ether), int256(1 ether), minRate, "");
        assertGt(tokenId, 0, "position not created");

        nectraUSD.approve(address(nectra), type(uint256).max);
        
        vm.warp(block.timestamp + 1 hours);
        uint256 out1 = nectra.redeem(0.1 ether, 0);
        // second redeem shortly after should have higher fee -> less collateral out
        vm.warp(block.timestamp + 5 minutes);
        uint256 out2 = nectra.redeem(0.1 ether, 0);
        assertLt(out2, out1, "redemption fee buffer did not increase (out2 >= out1)");
    }

    function test_CoreState_UpdatesWithPositionCreation() public {
        // Create position and borrow
        uint256 rate = systemParams.minimumInterestRate;
        uint256 collateral = 1 ether;
        uint256 debt = 0.4 ether;
        vm.deal(address(this), address(this).balance + collateral);
        (uint256 tokenId,, , ,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), rate, "");

        (NectraLib.PositionState memory p, NectraLib.BucketState memory b, NectraLib.GlobalState memory g) =
            nectra.getPositionState(tokenId);

        assertEq(p.tokenId, tokenId, "position tokenId");
        assertEq(p.collateral, collateral, "position collateral");
        assertGe(p.debtShares, debt, "position debt shares");

        // sanity on bucket/global
        assertEq(b.interestRate, p.interestRate, "bucket rate matches position");
        assertGe(g.totalDebtShares, debt, "global debt shares");
        assertGe(g.debt, debt, "global debt");
    }

    function test_Upgrade_PreservesConfigAndState() public {
        // Capture pre-upgrade config
        NectraBase.SystemParams memory beforeCfg = nectra.getConfig();

        // Create some state
        uint256 rate = systemParams.minimumInterestRate;
        uint256 collateral = 1 ether;
        uint256 debt = 0.2 ether;
        vm.deal(address(this), address(this).balance + collateral);
        (uint256 tokenId,, , ,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), rate, "");

        // Upgrade to a fresh implementation of Nectra (no init data)
        UnsafeUpgrades.upgradeProxy(address(nectra), address(new Nectra()), "");

        // Config should remain identical
        NectraBase.SystemParams memory afterCfg = nectra.getConfig();
        assertEq(abi.encode(beforeCfg), abi.encode(afterCfg), "config changed across upgrade");

        // State should remain sane and readable
        (NectraLib.PositionState memory p,,) = nectra.getPositionState(tokenId);
        assertEq(p.tokenId, tokenId, "position lost across upgrade");
        assertEq(p.collateral, collateral, "position collateral lost across upgrade");
        assertGe(p.debtShares, debt, "position debt shares lost across upgrade");
    }
}


