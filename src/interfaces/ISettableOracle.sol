// src/interfaces/ISettableOracle.sol
pragma solidity ^0.8.0;

interface ISettableOracle {
    function setPrice(address token, uint256 price) external;
}
