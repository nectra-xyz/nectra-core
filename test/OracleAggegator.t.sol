// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {OracleAggregator} from "src/OracleAggregator.sol";
import {AggregatorV3Mock} from "./mocks/AggregatorV3Mock.sol";

contract OracleAggregatorTest is Test {
    uint256 public constant UNIT = 10 ** 18;

    AggregatorV3Mock public primary;
    AggregatorV3Mock public secondary;
    OracleAggregator public oracle;

    uint8 public primaryDecimals = 8;
    uint8 public secondaryDecimals = 8;

    uint256 public initialPriceRaw = 110878;
    uint256 public primaryPriceRaw = 110881;
    uint256 public secondaryPriceRaw = 110879;

    uint256 public primaryPrice;
    uint256 public secondaryPrice;

    function setUp() public {
        primaryPrice = primaryPriceRaw * 10 ** primaryDecimals;
        secondaryPrice = secondaryPriceRaw * 10 ** secondaryDecimals;

        primary = new AggregatorV3Mock(initialPriceRaw * 10 ** primaryDecimals, vm.getBlockTimestamp(), primaryDecimals);
        secondary = new AggregatorV3Mock(secondaryPrice, vm.getBlockTimestamp(), secondaryDecimals);

        oracle = new OracleAggregator(address(primary), address(secondary), 24 hours, 12 hours);

        // set primary price to 110881
        primary.setLatestAnswer(int256(primaryPriceRaw * 10 ** primaryDecimals));

        vm.warp(vm.getBlockTimestamp() + 11 hours);
    }

    // isStale permutations: primary stale
    function test_should_use_secondary_price_when_primary_call_reverts() public {
        primary.setCallShouldRevert(true);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_secondary_price_when_primary_answer_is_zero() public {
        primary.setLatestAnswer(0);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_secondary_price_when_primary_answer_is_negative() public {
        primary.setLatestAnswer(-1);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_secondary_price_when_primary_answer_is_future_dated() public {
        // make primary answer future dated
        primary.setLatestTimestamp(vm.getBlockTimestamp() + 1);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_primary_answer_is_exactly_24_hours_old() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_secondary_price_when_primary_answer_is_more_than_24_hours_old() public {
        // let time pass so that primary is more than 24 hours old
        vm.warp(vm.getBlockTimestamp() + 13 hours + 1);

        // update secondary update timestamp
        secondary.setLatestTimestamp(vm.getBlockTimestamp());

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    // isStale permutations: secondary stale
    function test_should_use_primary_price_when_secondary_call_reverts() public {
        secondary.setCallShouldRevert(true);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_secondary_answer_is_zero() public {
        secondary.setLatestAnswer(0);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_secondary_answer_is_negative() public {
        secondary.setLatestAnswer(-1);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_secondary_answer_is_future_dated() public {
        // make secondary answer future dated
        secondary.setLatestTimestamp(vm.getBlockTimestamp() + 1);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_secondary_price_when_primary_is_outdated_and_secondary_is_not() public {
        // make both outdated
        vm.warp(vm.getBlockTimestamp() + 13 hours + 1);

        // make secondary fresh by 0 seconds
        secondary.setLatestTimestamp(vm.getBlockTimestamp() - 12 hours);

        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_secondary_answer_is_more_than_24_hours_old() public {
        // update primary update timestamp
        primary.setLatestTimestamp(vm.getBlockTimestamp());
        // let time pass so that primary is more than 24 hours old
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    // isStale permutations: neither stale or both stale
    function test_should_use_primary_price_when_neither_stale() public {
        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertFalse(isStale, "should not be stale");
    }

    function test_should_use_primary_price_when_both_stale() public {
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, primaryPriceRaw * UNIT, "price should be primary price");
        assertTrue(isStale);
    }

    function test_should_use_secondary_price_when_both_stale_and_primary_is_zero() public {
        primary.setLatestAnswer(0);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        (uint256 price, bool isStale) = oracle.getLatestPrice();
        assertEq(price, secondaryPriceRaw * UNIT, "price should be secondary price");
        assertTrue(isStale);
    }
}
