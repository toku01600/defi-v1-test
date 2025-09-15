// =============================================
// test/Oracle.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "src/PriceOracle.sol";


interface AggregatorV3InterfaceLike {
    function decimals() external view returns (uint8);
}


contract OracleTest is Test {
    // シンプルにモック代替（本来はChainlinkのMockを利用）
    PriceOracle oracle;


    // ダミーAgg（decimals=8固定でlatestRoundDataを返すコントラクトを後で用意しても良い）
    // ここでは setFeed 時の登録のみをテスト


    function setUp() public {
        oracle = new PriceOracle();
    }


    function testOwnerCanSetFeed() public {
        // このテストは setFeed を呼べることのみ検証（実稼働はChainlink実体を使う）
        address fakeAgg = address(0x1234);
        vm.mockCall(fakeAgg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(fakeAgg, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(1e8), uint256(0), uint256(1), uint80(1)));
        oracle.setFeed(address(0xAAA), fakeAgg);
        (int256 price, uint8 decs) = oracle.getPriceUsd(address(0xAAA));
        assertEq(price, int256(1e8));
        assertEq(decs, 8);
    }
}