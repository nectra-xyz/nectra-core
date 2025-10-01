// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Nectra, NectraBase} from "src/Nectra.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {NUSDToken} from "src/NUSDToken.sol";
import {NectraExternal} from "src/auxiliary/NectraExternal.sol";
import {OracleAggregatorMock} from "test/mocks/OracleAggregatorMock.sol";
import {SatsumaMock} from "test/mocks/SatsumaMock.sol";
import {WCBTCMock} from "test/mocks/WCBTCMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "src/interfaces/Satsuma/ISwapRouter.sol";
import {IQuoterV2} from "src/interfaces/Satsuma/IQuoterV2.sol";
import {MintableErc20} from "test/helpers/MintableErc20.sol";

import {console} from "forge-std/console.sol";

contract RedemptionBufferSimulation is Test {
    uint256 constant UNIT = 1 ether;

    Nectra internal nectra;
    NUSDToken internal nusd;
    NectraNFT internal nft;
    NectraExternal internal nectraExternal;
    OracleAggregatorMock internal oracle;
    WCBTCMock internal wcbtc;
    SatsumaMock internal dex;
    MintableErc20 internal usdc;

    address internal feeRecipient = address(0xfee);
    address internal treasury = address(0xdead);
    address internal otherUser = address(0xBEEF);
    address internal liquidityProvider = address(0x123);

    uint256 internal treasuryTokenId;
    uint256 internal otherUserTokenId;

    // simulation parameters
    uint256 public redemptionVolumePerDay = 100_000 ether; // in nUSD
    // buffer position parameters: 6 cBTC ($600,000) collateral, 300,000 nUSD debt
    uint256 treasuryCollateral = 10 ether; // denominated as cBTC wei at price scale
    uint256 treasuryDebt = 500_000 ether;
    // system debt parameters: 20 cBTC ($2,000,000) collateral and 1,150,000 nUSD debt
    uint256 sysCollateral = 1000 ether;
    uint256 sysDebt = 50_000_000 ether;

    function setUp() public {
        // oracle at 100,000 per BTC
        oracle = new OracleAggregatorMock(100_000 * UNIT);

        // deploy core via proxies
        address nectraProxy = UnsafeUpgrades.deployUUPSProxy(address(new Nectra()), "");
        nectra = Nectra(nectraProxy);

        address nftProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new NectraNFT()), abi.encodeCall(NectraNFT.initialize, (address(this), address(nectra)))
        );
        nft = NectraNFT(nftProxy);

        address nusdProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new NUSDToken()), abi.encodeCall(NUSDToken.initialize, (address(this), address(nectra)))
        );
        nusd = NUSDToken(nusdProxy);

        // initialize Nectra with requested params
        NectraBase.SystemParams memory p = NectraBase.SystemParams({
            nectraNFTAddress: address(nft),
            nusdTokenAddress: address(nusd),
            oracleAddress: address(oracle),
            feeRecipientAddress: feeRecipient,
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
            redemptionFeeTreasuryThreshold: type(uint256).max, // 0 -> Full fee left in bucket
            openFeePercentage: 0 ether, // 0.15%
            flashMintFee: 0.0025 ether, // 0.25%
            flashBorrowFee: 0.0025 ether // 0.25%
        });
        nectra.initialize(p);

        nectraExternal = new NectraExternal(address(nectra), address(nft));

        // deploy assets and DEX
        wcbtc = new WCBTCMock();
        usdc = new MintableErc20("USD Coin", "USDC", 6);
        dex = new SatsumaMock(address(nusd), address(usdc), address(nectra), address(oracle), address(wcbtc));

        // create treasury 0% position
        treasuryTokenId = _openPosition(treasury, treasuryCollateral, int256(treasuryDebt), 0);

        // create system user position at 2.5%
        otherUserTokenId = _openPosition(otherUser, sysCollateral, int256(sysDebt), 0.025 ether);

        vm.prank(otherUser);
        nusd.approve(address(nectra), type(uint256).max);

        // Setup initial DEX balances
        // Mint WCBTC to DEX by depositing cBTC
        uint256 liquidityAmount = 10 ether;
        deal(liquidityProvider, liquidityAmount); // 10 cBTC
        vm.startPrank(liquidityProvider);
        wcbtc.deposit{value: liquidityAmount}(); // Convert cBTC to WCBTC
        wcbtc.transfer(address(dex), liquidityAmount); // Give DEX 10 WCBTC
        vm.stopPrank();

        // Give DEX mock some USDC to handle swaps
        usdc.mint(address(dex), 1_000_000 * 10 ** 6); // 1M USDC for liquidity
        // Give DEX some nUSD from "other users"
        vm.prank(otherUser);
        nusd.transfer(address(dex), 1_000_000 * UNIT); // Give DEX 1M nUSD for liquidity
    }

    function test_simulateBufferRestoration_limits() public {
        uint256 lo = 0; // 0%
        uint256 hi = 0.11 ether; // 0.1% cap

        // binary search maximum slippage that still lets buffer restore using direct nUSD->WCBTC
        for (uint256 i = 0; i < 100; i++) {
            uint256 snapshot = vm.snapshotState();
            // perform a redemption first: burns otherUser nUSD, reduces bucket debt and removes some collateral
            uint256 redemptionFee = nectra.getRedemptionFee(redemptionVolumePerDay);
            (uint256 collateralInOtherPosition, uint256 debtInOtherPosition,) =
                nectraExternal.getPosition(otherUserTokenId);
            (uint256 collateralInPosition, uint256 debtInPosition,) = nectraExternal.getPosition(treasuryTokenId);

            vm.prank(otherUser);
            uint256 collateralRedeemed = nectra.redeem(redemptionVolumePerDay, 0);

            (collateralInOtherPosition, debtInOtherPosition,) = nectraExternal.getPosition(otherUserTokenId);

            // confirm redemption fee is in position
            (collateralInPosition, debtInPosition,) = nectraExternal.getPosition(treasuryTokenId);

            uint256 mid = (lo + hi) / 2;
            dex.setSlippageAndFees(mid);

            bool swapProfitable = _tryRestoreDirect();
            // revert to snapshot to restore state for next iteration
            vm.revertToState(snapshot);

            if (swapProfitable) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        console.log("Max slippage nUSD:WCBTC (approx)", lo);

        // two-hop via USDC: configure pair slippages; search for max combined slippage allowed
        // lo = 0; hi = 0.2 ether;
        // for (uint256 j = 0; j < 20; j++) {
        //     uint256 mid2 = (lo + hi) / 2;
        //     dex.setSlippageNUSDUSDC(mid2);
        //     dex.setSlippageUSDCWCBTC(mid2);
        //     bool ok2 = _tryRestoreViaUSDC(mid2);
        //     if (ok2) lo = mid2; else hi = mid2;
        // }
        // console.log("Max per-hop slippage nUSD:USDC and USDC:WCBTC (approx)", lo);
    }

    function _tryRestoreDirect() internal returns (bool) {
        // Simplified: assume redemption spent redemptionVolumePerDay nUSD;
        // treasury swaps nUSD to restore the redeemed collateral from the buffer;
        // treasury deposits the received cBTC into Nectra and borrows nUSD to restore
        // the nUSD used to pay for the swap. The redemption fee left in the position
        // should be enough to cover the fee and slippage for the swap.

        (uint256 collateralInPosition, uint256 debtInPosition,) = nectraExternal.getPosition(treasuryTokenId);
        // amountToRestore > collateralRedeemed when redemption fee is split between treasury and position
        uint256 amountToRestore = treasuryCollateral - collateralInPosition;

        vm.startPrank(treasury);
        // quote to determine the amount of nUSD needed to swap for the redeemed collateral
        (, uint256 nUSDToSwap,,,,) = dex.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(nusd),
                tokenOut: address(wcbtc),
                deployer: address(0),
                amount: amountToRestore,
                limitSqrtPrice: 0
            })
        );

        // if the quote exceeds the redemption volume, the swap fee + slippage will exceed the redemption fee
        if (nUSDToSwap >= redemptionVolumePerDay) {
            vm.stopPrank();
            return false;
        }

        // approve quoted nUSD for swap
        nusd.approve(address(dex), nUSDToSwap);
        // swap quoted amount of nUSD for WCBTC
        ISwapRouter.ExactOutputSingleParams memory pIn = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(nusd),
            tokenOut: address(wcbtc),
            deployer: address(0),
            recipient: treasury,
            deadline: block.timestamp + 300,
            amountOut: amountToRestore,
            amountInMaximum: nUSDToSwap,
            limitSqrtPrice: 0
        });

        uint256 amountSpent = dex.exactOutputSingle(pIn);

        // unwrap and restore position
        wcbtc.approve(address(wcbtc), amountToRestore);
        wcbtc.withdraw(amountToRestore);
        nectra.modifyPosition{value: amountToRestore}(treasuryTokenId, int256(amountToRestore), int256(nUSDToSwap), "");
        vm.stopPrank();

        (collateralInPosition, debtInPosition,) = nectraExternal.getPosition(treasuryTokenId);
        uint256 finalNusdBal = nusd.balanceOf(treasury);

        // profitable or break even if:
        // 1. collateral has increased or is the same
        // 2. debt is decreased or is the same
        // 3. nUSD balance has increased of is the same
        return
            collateralInPosition >= treasuryCollateral && debtInPosition <= treasuryDebt && finalNusdBal >= treasuryDebt;
    }

    function _tryRestoreViaUSDC(uint256) internal returns (bool) {
        // two-hop approximation: nUSD->USDC then USDC->WCBTC
        vm.startPrank(treasury);
        nusd.approve(address(dex), redemptionVolumePerDay);
        // hop 1
        (uint256 outUSDC,,,,,) = dex.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(nusd),
                tokenOut: address(dex.USDC()),
                deployer: address(0),
                amountIn: redemptionVolumePerDay,
                limitSqrtPrice: 0
            })
        );
        if (outUSDC == 0) {
            vm.stopPrank();
            return false;
        }
        ISwapRouter.ExactInputSingleParams memory p1 = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(nusd),
            tokenOut: address(dex.USDC()),
            deployer: address(0),
            recipient: treasury,
            deadline: block.timestamp + 300,
            amountIn: redemptionVolumePerDay,
            amountOutMinimum: outUSDC * 99 / 100,
            limitSqrtPrice: 0
        });
        try dex.exactInputSingle(p1) returns (uint256 gotUSDC) {
            // hop 2
            IERC20(dex.USDC()).approve(address(dex), gotUSDC);
            (uint256 outW,,,,,) = dex.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: address(dex.USDC()),
                    tokenOut: address(wcbtc),
                    deployer: address(0),
                    amountIn: gotUSDC,
                    limitSqrtPrice: 0
                })
            );
            if (outW == 0) {
                vm.stopPrank();
                return false;
            }
            ISwapRouter.ExactInputSingleParams memory p2 = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(dex.USDC()),
                tokenOut: address(wcbtc),
                deployer: address(0),
                recipient: treasury,
                deadline: block.timestamp + 300,
                amountIn: gotUSDC,
                amountOutMinimum: outW * 99 / 100,
                limitSqrtPrice: 0
            });
            try dex.exactInputSingle(p2) returns (uint256 gotW) {
                vm.stopPrank();
                return gotW >= outW * 99 / 100;
            } catch {
                vm.stopPrank();
                return false;
            }
        } catch {
            vm.stopPrank();
            return false;
        }
    }

    function _openPosition(address who, uint256 collateralCBTC, int256 debtNUSD, uint256 rate)
        internal
        returns (uint256)
    {
        uint256 currentSysInterestRate = nectra.getSystemInterestRate();

        // open position at specified interest rate
        nectra.storeSystemInterestRate(rate);

        vm.deal(who, collateralCBTC);
        vm.prank(who);
        (uint256 tokenId,,,,) = nectra.modifyPosition{value: collateralCBTC}(0, int256(collateralCBTC), debtNUSD, "");

        // restore system interest rate
        nectra.storeSystemInterestRate(currentSysInterestRate);

        return tokenId;
    }
}
