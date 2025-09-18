// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregatorMock} from "test/mocks/OracleAggregatorMock.sol";
import {InitialImplementation} from "src/initialImplementation.sol";

// use UnsafeUpgrades to deploy and upgrade the contracts during testing only
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

abstract contract NectraBaseTest is Test {
    uint256 constant UNIT = 1 ether;

    NUSDToken internal nectraUSD;
    NectraNFT internal nectraNFT;
    Nectra internal nectra;
    NectraExternal internal nectraExternal;
    OracleAggregatorMock internal oracle;

    address whale = makeAddr("whale");
    address feeRecipient = makeAddr("feeRecipient");

    NectraBase.SystemParams internal systemParams = NectraBase.SystemParams({
        nectraNFTAddress: address(0),
        nusdTokenAddress: address(0),
        oracleAddress: address(0),
        feeRecipientAddress: feeRecipient,
        minimumCollateral: 0.1 ether,
        minimumDebt: 0.1 ether,
        systemInterestRate: 0.0025 ether, // 0.25%
        maximumInterestRate: 1 ether,
        minimumInterestRate: 0.0001 ether, // 0%
        interestRateIncrement: 0.0001 ether, // 0.01%
        liquidationRatio: 1.2 ether,
        liquidatorRewardPercentage: 0.85 ether,
        liquidationPenaltyPercentage: 0.05 ether,
        fullLiquidationRatio: 1.1 ether,
        fullLiquidationFee: 5 ether,
        maximumLiquidatorReward: 5 ether,
        issuanceRatio: 1.4 ether,
        redemptionFeeDecayPeriod: 6 hours,
        redemptionBaseFee: 0 ether,
        redemptionDynamicFeeScalar: 0,
        redemptionFeeTreasuryThreshold: type(uint256).max,
        openFeePercentage: 0 ether,
        flashMintFee: 0.009 ether, // 0.9%
        flashBorrowFee: 0.009 ether // 0.9%
    });

    function setUp() public virtual {
        oracle = new OracleAggregatorMock(1.2 ether);

        // deploy nectra with the initial implementation to get an address for core
        address nectraProxy = UnsafeUpgrades.deployUUPSProxy(address(new InitialImplementation()), "");
        nectra = Nectra(nectraProxy);

        // deploy nft with the initial implementation to get an address for core
        address nftProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new NectraNFT()),
            abi.encodeCall(NectraNFT.initialize, (address(this), address(nectra)))
        );
        nectraNFT = NectraNFT(nftProxy);
        
        // deploy nUSD
        address nusdProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new NUSDToken()),
            abi.encodeCall(NUSDToken.initialize, (address(this), address(nectra)))
        );
        nectraUSD = NUSDToken(nusdProxy);

        // upgrade nectra to the final implementation
        Nectra.SystemParams memory _params = systemParams;
        _params.nectraNFTAddress = address(nectraNFT);
        _params.nusdTokenAddress = address(nectraUSD);
        _params.oracleAddress = address(oracle);

        UnsafeUpgrades.upgradeProxy(
            nectraProxy,
            address(new Nectra()),
            abi.encodeCall(Nectra.initialize, (_params))
        );

        nectraExternal = new NectraExternal(address(nectra), address(nectraNFT));

        deal(address(this), 1_000_000 ether);
    }

    function _checkPosition(
        uint256 tokenId,
        uint256 expectedCollateral,
        uint256 expectedDebt,
        uint256 expectedInterestRate
    ) internal view {
        (NectraLib.PositionState memory positionState,,) = nectra.getPositionState(tokenId);
        uint256 positionDebt = nectraExternal.getPositionDebt(tokenId);
        assertApproxEqRel(positionState.collateral, expectedCollateral, 1e11, "Position collateral mismatch");
        assertApproxEqRel(positionDebt, expectedDebt, 1e11, "Position debt mismatch");
        assertEq(positionState.interestRate, expectedInterestRate, "Position interest rate mismatch");
    }

    function _checkPositionRedemptionAccumulator(
        uint256 tokenId,
        uint256 expectedAccumulatedRedeemedCollateralPerShare,
        uint256 expectedLastBucketAccumulatedRedeemedCollateralPerShare
    ) internal view {
        (NectraLib.PositionState memory positionState, NectraLib.BucketState memory bucketState,) =
            nectra.getPositionState(tokenId);
        assertEq(
            bucketState.accumulatedRedeemedCollateralPerShare,
            expectedAccumulatedRedeemedCollateralPerShare,
            "Bucket redemption accumulator mismatch"
        );
        assertEq(
            positionState.lastBucketAccumulatedRedeemedCollateralPerShare,
            expectedLastBucketAccumulatedRedeemedCollateralPerShare,
            "Position redemption accumulator mismatch"
        );
    }

    function _checkBucketLiquidationAccumulators(
        uint256 interestRate,
        uint256 expectedAccumulatedLiquidatedCollateralPerShare,
        uint256 expectedAccumulatedLiquidatedDebtPerShare
    ) internal view {
        (NectraLib.BucketState memory bucketState,) = nectra.getBucketState(interestRate);
        assertEq(
            bucketState.lastGlobalAccumulatedLiquidatedCollateralPerShare,
            expectedAccumulatedLiquidatedCollateralPerShare,
            "Liquidation collateral accumulator mismatch"
        );
        assertEq(
            bucketState.lastGlobalAccumulatedLiquidatedDebtPerShare,
            expectedAccumulatedLiquidatedDebtPerShare,
            "Liquidation debt accumulator mismatch"
        );
    }

    receive() external payable {
        // This function is intentionally left empty
    }
}
