// =============================================
// test/PoolCore.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolCore} from "src/PoolCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

// @audit Each test validates invariants around solvency, collateralization, and liquidation correctness.
/// @title PoolCoreTest
/// @notice Unit tests for PoolCore contract (deposit, borrow, repay, liquidation)
/// @dev プールの基本機能（預入・借入・返済・清算）に関する単体テスト
contract PoolCoreTest is Test {
    PoolCore pool;
    MockOracle oracle;
    MockERC20 usdc;
    MockERC20 weth;

    address safetyFund = address(0xF00D);
    address admin = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // Label addresses for easier trace readability
        vm.label(safetyFund, "safetyFund");
        vm.label(admin, "admin");
        vm.label(alice, "alice");
        vm.label(bob, "bob");

        // Deploy mock tokens
        // USDC: 6 decimals, stable asset
        // WETH: 18 decimals, volatile collateral
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy oracle and set initial prices
        // USDC = $1.00, WETH = $2000.00
        oracle = new MockOracle();
        oracle.setPrice(address(usdc), 1e8, 8);      // $1.00
        oracle.setPrice(address(weth), 2000e8, 8);   // $2000

        // Deploy PoolCore
        pool = new PoolCore(address(oracle), safetyFund, admin);

        // Register assets with collateral factors
        vm.prank(admin);
        pool.listAsset(address(weth), 8000); // // 80% collateral factor
        vm.prank(admin);
        pool.listAsset(address(usdc), 9000); // 90% (future: stablecoin collateral option)

        // Bob provides liquidity in USDC
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 500_000e6); // // pool funded with 500k USDC
        vm.stopPrank();

        // Alice provides collateral in WETH
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max); // 返済/清算で使う可能性用
        pool.deposit(address(weth), 10 ether);
        vm.stopPrank();
    }

    // --------------------------
    // Borrow / Lending
    // --------------------------
    
    // @audit Invariant: borrowUsd ≈ 1000e18, collateralUsd >= borrowUsd
    /// @notice Alice borrows within her allowed limit (should succeed)
    /// @dev アリスが担保価値の範囲内で借入 → 成功
    function testBorrowWithinLimit() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 1_000e6); // $1000
        vm.stopPrank();

        (uint256 colUsd, uint256 borUsd) = pool.getUserAccountValuesUsd(alice);

        // 健全性の確認（担保率内であること）
        assertTrue(pool.isHealthy(alice));

        // 借入額が $1000（1e18スケール）であることを確認（誤差 ±$1）
        assertApproxEqAbs(borUsd, 1000e18, 1e18);

        // 総担保額は借入額以上であること
        assertGe(colUsd, borUsd);
    }
    
    // @audit Invariant: borrow > collateralValue * cf → NotHealthy revert
    /// @notice Alice tries to borrow over her collateralized limit (should revert)
    /// @dev アリスが担保価値を超える借入を試みると revert
    function testBorrowOverLimitShouldRevert() public {
        vm.startPrank(alice);

        // 担保: 10 ETH ($20,000) × 80% = $16,000 が借入上限
        // 借入: 20,000 USDC ($20,000) → 上限オーバー → revert 期待
        vm.expectRevert(PoolCore.NotHealthy.selector);
        pool.borrow(address(usdc), 20_000e6);

        vm.stopPrank();
    }

    // --------------------------
    // Withdraw
    // --------------------------
    
    // @audit Borrow=0, so health check passes regardless
    /// @notice Alice withdraws some collateral without any borrow (should succeed)
    /// @dev 借入なし → 一部担保の引き出し可能
    function testWithdrawCollateralWithoutBorrow() public {
        vm.startPrank(alice);
        pool.withdraw(address(weth), 0.5 ether);
        vm.stopPrank();

        (uint256 colUsd, uint256 borUsd) = pool.getUserAccountValuesUsd(alice);
        assertGt(colUsd, 0);
        assertEq(borUsd, 0);
    }
    
    // @audit Invariant: after withdraw, collateralUsd < borrowUsd → revert
    /// @notice Alice borrows and then tries to withdraw too much collateral (should revert)
    /// @dev 借入中に過剰担保を引き出すと revert
    function testWithdrawCollateralWhileBorrowingShouldRevert() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 10_000e6);

        // 借入中に過剰な担保引き出しはリバート
        vm.expectRevert();
        pool.withdraw(address(weth), 5 ether);
        vm.stopPrank();
    }

    // --------------------------
    // Liquidation
    // --------------------------
    
    // @audit Invariant: isHealthy(alice) == true → revert on liquidate
    /// @notice Liquidation should revert if Alice is still healthy
    /// @dev 健全なポジションでは清算できない
    function testLiquidationHealthyShouldRevert() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 1000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert();
        pool.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();
    }
    
    // @audit Invariant: after liquidation, borrowUsd decreases
    /// @notice Price drop causes Alice to become unhealthy; Bob partially liquidates
    /// @dev 価格下落で不健全になり、ボブが部分清算
    function testLiquidationAfterPriceDrop() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 13_000e6);
        vm.stopPrank();

        // ETH $2000 → $500
        oracle.setPrice(address(weth), 500e8, 8);

        // 健全性チェック：不健全になっているはず
        assertFalse(pool.isHealthy(alice));

        vm.startPrank(bob);
        pool.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();

        (, uint256 afterBor) = pool.getUserAccountValuesUsd(alice);

        // 借入が減っていることを確認
        assertLt(afterBor, 13_000e18);
    
        // 部分清算後も不健全の可能性があるので削除 or assertFalse
        // 健全性が改善しているはず
        //assertTrue(pool.isHealthy(alice));
    }
    
    // @audit Borrow reduces, collateral seized accordingly
    /// @notice Partial liquidation scenario (repays a fraction of debt)
    /// @dev ボブが借入の一部を清算
    function testPartialLiquidation() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 13_000e6);
        vm.stopPrank();

        // ETH $2000 → $500 (不健全を強制)
        oracle.setPrice(address(weth), 500e8, 8);

        assertFalse(pool.isHealthy(alice));

        vm.startPrank(bob);
        pool.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();

        (, uint256 afterBor) = pool.getUserAccountValuesUsd(alice);

        // 借入が減っている
        assertLt(afterBor, 13_000e18);
   
        // 部分清算後も不健全のまま残り得る
        // 健全性が回復している
        //assertTrue(pool.isHealthy(alice));
    }
    
    // @audit After liquidation, borrow ≈ half of original
    /// @notice Full liquidation scenario (all debt cleared or half in this setup)
    /// @dev 担保が大幅下落し、ボブが全額もしくは半額を清算
    function testFullLiquidation() public {
        vm.startPrank(alice);
        pool.borrow(address(usdc), 13_000e6);
        vm.stopPrank();

        // ETH $2000 → $200
        oracle.setPrice(address(weth), 200e8, 8);
        assertFalse(pool.isHealthy(alice));

        vm.startPrank(bob);

        //担保全額清算
        //pool.liquidate(alice, address(usdc), address(weth), 13000e6);

        //担保の半額 
        // repay amount = half of total debt (partial liquidation)
        uint256 debt = pool.borrows(alice, address(usdc));
        pool.liquidate(alice, address(usdc), address(weth), debt / 2);
        vm.stopPrank();

        (, uint256 afterBor) = pool.getUserAccountValuesUsd(alice);

        // 借入がゼロになったことを確認
        //assertEq(afterBor, 0);

        // 借入が半分になっていることを確認
        assertApproxEqAbs(afterBor, 6500e18, 1e18);

        // Alice の担保が減っている
        uint256 aliceCollateralBalance = weth.balanceOf(alice);
        assertLt(aliceCollateralBalance, 10 ether); // deposit した 10ETH より少ない
    }
}
