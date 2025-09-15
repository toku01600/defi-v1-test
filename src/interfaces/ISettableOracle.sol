// =============================================
// src/interfaces/ISettableOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISettableOracle {
    function setPrice(address token, uint256 price) external;
}
