// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {NectraBaseTest, console2} from "test/NectraBase.t.sol";

import {NUSDToken} from "src/NUSDToken.sol";
import {NectraNFT} from "src/NectraNFT.sol";
import {Nectra} from "src/Nectra.sol";
import {NectraLib} from "src/NectraLib.sol";
import {OracleAggregator} from "src/OracleAggregator.sol";

contract NectraLiquidationsTest is NectraBaseTest {
    uint256[] internal tokens;

    function setUp() public virtual override {
        cargs.openFeePercentage = 0; // Disable open fee for testing
        super.setUp();

        uint256 tokenId;
        // Open positions with different interest rates

        (tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 10 ether, 0.05 ether, "");
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 85 ether, 0.05 ether, "");
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 20 ether, 0.05 ether, "");
        tokens.push(tokenId);

        (tokenId,,,,) = nectra.modifyPosition{value: 100 ether}(0, 100 ether, 20 ether, 0.05 ether, "");
        tokens.push(tokenId);
    }

    function test_liquidate_full() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        oracle.setCurrentPrice(0.88 ether);

        nectra.fullLiquidate(tokens[1]);
    }

    function test_liquidate_partial() public {
        nectraUSD.approve(address(nectra), type(uint256).max);

        oracle.setCurrentPrice(1.02 ether);

        nectra.liquidate(tokens[1]);

        assertApproxEqRel(nectraExternal.getPositionDebt(tokens[1]), 40.375 ether, 1e11);
        assertApproxEqRel(nectraExternal.getPositionCollateral(tokens[1]), 55.416666666666666665 ether, 1e11);
    }
}
