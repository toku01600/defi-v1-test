// =============================================
// test/AdvancedScenariosAttackTests.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PoolCore} from "../src/PoolCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract AdvancedScenariosAttackTest is Test {
    PoolCore public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;

    address attacker = address(0xDEAD);
    address safetyFund = address(0xF00D);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new MockOracle();
        oracle.setPrice(address(usdc), 1e8, 8);
        oracle.setPrice(address(weth), 2000e8, 8);
        pool = new PoolCore(address(oracle), safetyFund, address(this));
        pool.grantRole(pool.ADMIN_ROLE(), address(this));
        pool.listAsset(address(usdc), 9000);
        pool.listAsset(address(weth), 8000);
    }

    function testFlashLoanAttackResistance() public {
        // 仮のフラッシュローン攻撃シナリオ
        uint256 flashAmount = 1_000_000e6;
        usdc.mint(attacker, flashAmount);
        vm.startPrank(attacker);
        usdc.approve(address(pool), flashAmount);
        // 攻撃コード例: borrow->repayを悪用しないかチェック
        vm.expectRevert();
        pool.borrow(address(usdc), flashAmount);
        vm.stopPrank();
    }
}
