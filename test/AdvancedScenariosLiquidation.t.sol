// =============================================
// test/AdvancedScenariosLiquidation.t.sol
// =============================================
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockOracle.sol";
import "../src/PoolCore.sol";

contract AdvancedScenariosLiquidationTest is Test {
    PoolCore pool;
    MockERC20 collateral;
    MockERC20 borrowAsset;
    MockOracle oracle;

    address user1 = address(0xD0D);
    address user2 = address(0xB0B);

    function setUp() public {
        // 1. モックオラクル作成
        oracle = new MockOracle();

        // 2. モックERC20作成（初期供給量0で作成）
        collateral = new MockERC20("Collateral", "COL", 0);
        borrowAsset = new MockERC20("BorrowAsset", "BOR", 0);

        // 3. PoolCore作成（コンストラクタ引数は oracle, safetyFund, admin）
        pool = new PoolCore(address(oracle), address(this), address(this));

        // 4. PoolCore にコラテラルトークンを登録
        pool.registerCollateral(address(collateral));

        // 5. ユーザーに初期ERC20を配布
        collateral.mint(user1, 1e20); // 100 COL
        collateral.mint(user2, 1e20); // 100 COL
        borrowAsset.mint(user1, 1e22); // 10000 BOR
        borrowAsset.mint(user2, 1e22); // 10000 BOR
    }

    function testExtremePriceDropLiquidation() public {
        // 1. user1として操作
        vm.startPrank(user1);

        // 2. プールにコラテラルをデポジット
        collateral.approve(address(pool), type(uint256).max);
        pool.deposit(address(collateral), 1e19); // 10 COL

        // 3. プールから資産を借りる
        borrowAsset.approve(address(pool), type(uint256).max);
        pool.borrow(address(borrowAsset), 5e21); // 5000 BOR

        // 4. 価格が急落 → ユーザー清算可能
        oracle.setPrice(address(collateral), 1e16); // 価格を下げる
        pool.liquidate(user1, address(borrowAsset), address(collateral), 1e21); // 1000 BOR相当

        vm.stopPrank();
    }

    function testMultiUserLiquidation() public {
        // 1. user1操作
        vm.startPrank(user1);
        collateral.approve(address(pool), type(uint256).max);
        pool.deposit(address(collateral), 5e18); // 5 COL
        borrowAsset.approve(address(pool), type(uint256).max);
        pool.borrow(address(borrowAsset), 2e21); // 2000 BOR
        vm.stopPrank();

        // 2. user2操作
        vm.startPrank(user2);
        collateral.approve(address(pool), type(uint256).max);
        pool.deposit(address(collateral), 5e18); // 5 COL
        borrowAsset.approve(address(pool), type(uint256).max);
        pool.borrow(address(borrowAsset), 2e21); // 2000 BOR
        vm.stopPrank();

        // 3. 価格急落 → 両ユーザー清算
        oracle.setPrice(address(collateral), 1e16); 
        pool.liquidate(user1, address(borrowAsset), address(collateral), 5e20);
        pool.liquidate(user2, address(borrowAsset), address(collateral), 5e20);
    }

    function testSequentialPartialLiquidation() public {
        vm.startPrank(user1);
        collateral.approve(address(pool), type(uint256).max);
        pool.deposit(address(collateral), 1e19); // 10 COL
        borrowAsset.approve(address(pool), type(uint256).max);
        pool.borrow(address(borrowAsset), 5e21); // 5000 BOR
        vm.stopPrank();

        oracle.setPrice(address(collateral), 5e15); // 価格下落
        pool.liquidate(user1, address(borrowAsset), address(collateral), 1e21); // 部分清算
    }
}
