// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregatorMock} from "test/mocks/OracleAggregatorMock.sol";

abstract contract NectraBaseTest is Test {
    uint256 constant UNIT = 1 ether;

    NUSDToken internal nectraUSD;
    NectraNFT internal nectraNFT;
    Nectra internal nectra;
    NectraExternal internal nectraExternal;
    OracleAggregatorMock internal oracle;

    address whale = makeAddr("whale");
    address feeRecipient = makeAddr("feeRecipient");

    NectraBase.ConstructorArgs internal cargs = NectraBase.ConstructorArgs({
        nectraNFTAddress: address(0),
        nusdTokenAddress: address(0),
        oracleAddress: address(0),
        feeRecipientAddress: feeRecipient,
        minimumCollateral: 0.1 ether,
        minimumDebt: 0.1 ether,
        maximumInterestRate: 1 ether,
        minimumInterestRate: 0.005 ether, // 0.5%
        interestRateIncrement: 0.001 ether, // 0.1%
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
        nectraNFT = new NectraNFT(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2));
        nectraUSD = new NUSDToken(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));

        Nectra.ConstructorArgs memory _cargs = cargs;
        _cargs.nectraNFTAddress = address(nectraNFT);
        _cargs.nusdTokenAddress = address(nectraUSD);
        _cargs.oracleAddress = address(oracle);

        nectra = new Nectra(_cargs);

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
