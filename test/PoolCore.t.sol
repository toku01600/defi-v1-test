// =============================================
// test/PoolCore.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import "forge-std/Test.sol";
import {PoolCore, IPriceOracle} from "src/PoolCore.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";


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
        // トークン（USDC:6, WETH:18）
        usdc = new MockERC20("USD Coin", "USDC", 6, 0, address(this));
        weth = new MockERC20("Wrapped Ether", "WETH", 18, 0, address(this));


        // オラクル
        oracle = new MockOracle();
        oracle.setPriceUSD(address(usdc), 1e8); // $1.00
        oracle.setPriceUSD(address(weth), 2000 * 1e8); // $2000


        // プール
        pool = new PoolCore(address(oracle), safetyFund, admin);
        // 資産登録（ETH=70%, USDC=80%）
        vm.prank(admin);
        pool.listAsset(address(weth), 7000);
        vm.prank(admin);
        pool.listAsset(address(usdc), 8000);


        // 流動性確保: BobがUSDCをプールに預ける
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 500_000e6);
        vm.stopPrank();


        // Alice にWETHを配布し担保預入
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 1 ether); // 担保=$2000, CF70% → 借入可能$1400
        vm.stopPrank();
    }
    
    function testBorrowWithinLimit() public {
    vm.startPrank(alice);
    pool.borrow(address(usdc), 1_000e6); // $1000 ← 余裕
    vm.stopPrank();


    (uint256 colUSD, uint256 borUSD) = pool.getUserAccountValuesUSD(alice);
    assertGe(colUSD, borUSD);
    }


    function testLiquidationAfterPriceDrop() public {
        // Alice 借入 $1,300（清算ギリ手前）
        vm.startPrank(alice);
        pool.borrow(address(usdc), 1_300e6);
        vm.stopPrank();


        // ETH 価格下落 $2000 → $1500（CF70% * 1500 = 1050 < 借入1300 → unhealthy）
        oracle.setPriceUSD(address(weth), 1500 * 1e8);
        assertFalse(pool.isHealthy(alice));


        // 清算者（Bob）が$500 返済し、その分のWETHを差し押さえ
        vm.startPrank(bob);
        // Bob のUSDCは既に大量にある
        pool.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();


        // 借入が減少しているか 
        (, uint256 afterBor) = pool.getUserAccountValuesUSD(alice);
        assertLt(afterBor, 1_300e6); // USD換算
    }
}