// =============================================
// test/mocks/MockOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

contract MockOracle is IPriceOracle {
    struct Price { int256 value; uint8 decimals; }
    mapping(address => Price) public prices;

    function setPrice(address asset, int256 value, uint8 decimals) external {
        prices[asset] = Price(value, decimals);
    }

    function getPriceUsd(address asset) external view override returns (int256, uint8) {
        Price memory p = prices[asset];
        require(p.value > 0, "MockOracle: price not set");
        return (p.value, p.decimals);
    }
}
