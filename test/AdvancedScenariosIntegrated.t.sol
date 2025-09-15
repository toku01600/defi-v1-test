// =============================================
// test/AdvancedScenariosIntegrated.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PoolCore} from "../src/PoolCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract AdvancedScenariosIntegratedTest is Test {
    PoolCore public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address charlie = address(0xC0DE);
    address david = address(0xD0D);
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

        // mint and approve for users
        address[4] memory users = [alice, bob, charlie, david];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000e6);
            weth.mint(users[i], 100 ether);
            vm.startPrank(users[i]);
            usdc.approve(address(pool), type(uint256).max);
            weth.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        // Approve pool for this test contract (as liquidator)
        usdc.mint(address(this), 1_000_000e6);
        weth.mint(address(this), 100 ether);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
    }

    function testComplexScenario() public {
        // Deposits
        vm.startPrank(alice); pool.deposit(address(weth), 10 ether); vm.stopPrank();
        vm.startPrank(bob); pool.deposit(address(usdc), 500_000e6); vm.stopPrank();

        // Borrow
        vm.startPrank(alice); pool.borrow(address(usdc), 10_000e6); vm.stopPrank();

        // Price shock
        oracle.setPrice(address(weth), 500e8, 8);

        // Liquidation candidates
        address[4] memory candidates = [alice, bob, charlie, david];
        for (uint256 i = 0; i < candidates.length; i++) {
            address user = candidates[i];
            if (pool.canBeLiquidated(user)) {
                uint256 debt = pool.borrows(user, address(usdc));
                uint256 repay = debt > 10_000e6 ? 10_000e6 : debt;
                if (repay > 0) {
                    // test contract acts as liquidator
                    pool.liquidate(user, address(usdc), address(weth), repay);
                }
            }
        }

        // Invariants
        assertGe(pool.totalDeposits(address(usdc)), pool.totalBorrows(address(usdc)));
        assertGe(pool.totalDeposits(address(weth)), pool.totalBorrows(address(weth)));

        // Users solvent
        address[4] memory users = [alice, bob, charlie, david];
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 colUsd, uint256 borUsd) = pool.getUserAccountValuesUsd(users[i]);
            assertGe(colUsd, borUsd);
        }
    }
}
