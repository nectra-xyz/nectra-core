// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {NectraLib} from "src/NectraLib.sol";
import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";

import {ERC1967Proxy} from "src/lib/ERC1967Proxy.sol";

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

    NectraBase.SystemParams internal systemParams = NectraBase.SystemParams({
        nectraNFTAddress: address(0),
        nusdTokenAddress: address(0),
        oracleAddress: address(0),
        feeRecipientAddress: feeRecipient,
        minimumCollateral: 0.1 ether,
        minimumDebt: 0.1 ether,
        systemInterestRate: 0.0025 ether, // 0.25%
        maximumInterestRate: 1 ether,
        minimumInterestRate: 0, // 0%
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
        Nectra nectraImplementation = new Nectra();
        ERC1967Proxy nectraProxy = new ERC1967Proxy(
            address(nectraImplementation),
            bytes("") // no initializer data
        );
        nectra = Nectra(address(nectraProxy));

        // deploy nft
        NectraNFT nectraNFTImplementation = new NectraNFT();
        ERC1967Proxy nftProxy = new ERC1967Proxy(
            address(nectraNFTImplementation),
            abi.encodeWithSelector(
                NectraNFT.initialize.selector,
                address(this), // owner
                address(nectra) // minter
            )
        );
        nectraNFT = NectraNFT(address(nftProxy));

        // deploy nUSD
        NUSDToken nectraUSDImplementation = new NUSDToken();
        ERC1967Proxy nusdProxy = new ERC1967Proxy(
            address(nectraUSDImplementation),
            abi.encodeWithSelector(
                NUSDToken.initialize.selector,
                address(this), // owner
                address(nectra) // minter
            )
        );
        nectraUSD = NUSDToken(address(nusdProxy));

        // upgrade nectra to the final implementation
        Nectra.SystemParams memory _params = systemParams;
        _params.nectraNFTAddress = address(nectraNFT);
        _params.nusdTokenAddress = address(nectraUSD);
        _params.oracleAddress = address(oracle);

        nectra.initialize(_params);

        nectraExternal = new NectraExternal(address(nectra), address(nectraNFT));

        deal(address(this), 1_000_000 ether);
    }

    function _createPosition(address user, uint256 collateral, uint256 debt, uint256 interestRate)
        internal
        returns (uint256 tokenId)
    {
        vm.deal(user, collateral);

        uint256 currentInterestRate = nectra.getSystemInterestRate();
        nectra.storeSystemInterestRate(interestRate);

        vm.prank(user);
        (tokenId,,,,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), "");

        // restore system interest rate
        nectra.storeSystemInterestRate(currentInterestRate);
    }

    function _createBuffer(uint256 collateral, uint256 debt, address bufferManager)
        internal
        returns (uint256 tokenId)
    {
        nectra.storeRedemptionBuffer(0, bufferManager);

        vm.deal(bufferManager, bufferManager.balance + collateral);

        vm.prank(bufferManager);
        (tokenId,,,,) = nectra.modifyPosition{value: collateral}(0, int256(collateral), int256(debt), "");
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
