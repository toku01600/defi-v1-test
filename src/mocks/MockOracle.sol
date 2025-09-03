// =============================================
// src/mocks/MockOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


interface ISettableOracle {
    function setPriceUSD(address asset, uint256 price8) external;
}


contract MockOracle is IPriceOracle, ISettableOracle {
    // asset => price(8 decimals)
    mapping(address => uint256) public prices;


    function setPriceUSD(address asset, uint256 price8) external { prices[asset] = price8; }


    function getPriceUSD(address asset) external view returns (int256 price, uint8 decimals) {
        uint256 p = prices[asset];
        require(p > 0, "price not set");
        return (int256(p), 8);
    }
}