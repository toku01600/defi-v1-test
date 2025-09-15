// =============================================
// src/interfaces/IPriceOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracle {
    function getPriceUsd(address asset) external view returns (int256, uint8);
}
