// =============================================
// src/interfaces/IPriceOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


interface IPriceOracle {
    /// @notice USD建て価格を返す
    /// @dev decimals は通常 Chainlink と同じ 8
    function getPriceUsd(address asset) external view returns (int256 price, uint8 decimals);
}