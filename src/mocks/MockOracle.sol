// =============================================
// src/mocks/MockOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

contract MockOracle is IPriceOracle {
    struct PriceData { int256 price; uint8 decimals; }
    mapping(address => PriceData) public prices;

    function setPrice(address asset, int256 price, uint8 decimals) external {
        require(price > 0, "invalid price");
        prices[asset] = PriceData(price, decimals);
    }

    function getPriceUsd(address asset) external view returns (int256, uint8) {
        PriceData memory p = prices[asset];
        require(p.price > 0, "no price");
        return (p.price, p.decimals);
    }
}

