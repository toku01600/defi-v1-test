// =============================================
// src/PriceOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/// @title PriceOracle - ChainlinkベースのUSD価格オラクル（8桁正規化）
contract PriceOracle is Ownable {
    struct FeedInfo { AggregatorV3Interface feed; uint8 decimals; }
    mapping(address => FeedInfo) public feeds; // asset => feed


    event FeedSet(address indexed asset, address indexed feed, uint8 decimals);


    constructor() {}


    function setFeed(address asset, address aggregator) external onlyOwner {
        AggregatorV3Interface f = AggregatorV3Interface(aggregator);
        feeds[asset] = FeedInfo({feed: f, decimals: f.decimals()});
        emit FeedSet(asset, aggregator, f.decimals());
    }


    /// @notice USD価格（8 decimalsに正規化）
    function getPriceUsd(address asset) external view returns (int256 price, uint8 decimals) {
        FeedInfo memory info = feeds[asset];
        require(address(info.feed) != address(0), "Oracle:feed not set");
        (, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = info.feed.latestRoundData();
        require(answer > 0 && updatedAt != 0 && answeredInRound != 0, "Oracle:stale/invalid");
        uint256 p = uint256(answer);
        if (info.decimals > 8) p = p / (10 ** (info.decimals - 8));
        else if (info.decimals < 8) p = p * (10 ** (8 - info.decimals));
        return (int256(p), 8);
    }
}