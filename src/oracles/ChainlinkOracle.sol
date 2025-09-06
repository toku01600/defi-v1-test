// =============================================
// src/oracles/ChainlinkOracle.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from
    "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title ChainlinkOracle
/// @notice IPriceOracle を実装した Chainlink ベースのオラクル
contract ChainlinkOracle is IPriceOracle {
    /// @dev 各アセットに対応する Chainlink feed
    mapping(address => AggregatorV3Interface) public feeds;

    event FeedSet(address indexed asset, address indexed feed);

    /// @notice 管理者がアセットに対して feed をセット
    function setFeed(address asset, address feed) external {
        require(asset != address(0) && feed != address(0), "bad param");
        feeds[asset] = AggregatorV3Interface(feed);
        emit FeedSet(asset, feed);
    }

    /// @inheritdoc IPriceOracle
    function getPriceUsd(address asset) external view returns (int256, uint8) {
        AggregatorV3Interface feed = feeds[asset];
        require(address(feed) != address(0), "no feed");

        (
            , // roundId
            int256 answer, // price
            , // startedAt
            uint256 updatedAt,
            // answeredInRound
        ) = feed.latestRoundData();

        require(answer > 0, "bad price");
        require(updatedAt != 0 && block.timestamp - updatedAt < 1 days, "stale price");

        return (answer, feed.decimals());
    }
}
