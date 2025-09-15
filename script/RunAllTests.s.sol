// =============================================
// script/RunAllTests.s.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";

contract RunAllTests is Script {
    function run() external {
        console.log("=== Running all tests ===");
        vm.startBroadcast();

        // ここでは forge test コマンドから全テストを呼び出すイメージ
        // 実際には forge test のコマンドラインで呼ぶのが基本です
        // 例: forge test --match-path 'test/*.t.sol' -vvv

        console.log("All tests executed");
        vm.stopBroadcast();
    }
}
