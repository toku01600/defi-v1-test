// =============================================
// test/helpers/PoolCoreHandler.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/PoolCore.sol";
import "../mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract PoolCoreHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PoolCore public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    address[] public users;
    address[] public assets;

    constructor(
        PoolCore _pool,
        MockERC20 _usdc,
        MockERC20 _weth,
        address[] memory _users
    ) {
        pool = _pool;
        usdc = _usdc;
        weth = _weth;
        users = _users;

        // 対象資産リスト
        assets = [address(usdc), address(weth)];
    }

    // --- Core Actions ---

    function deposit(address u, address asset, uint256 amount) public {
        vm.startPrank(u);
        IERC20(asset).approve(address(pool), amount);
        pool.deposit(asset, amount);
        vm.stopPrank();
    }

    function withdraw(address u, address asset, uint256 amount) public {
        vm.startPrank(u);
        pool.withdraw(asset, amount);
        vm.stopPrank();
    }

    function borrow(address u, uint256 amount) public {
        vm.startPrank(u);
        pool.borrow(address(usdc), amount); // 借入はUSDC固定
        vm.stopPrank();
    }

    function repay(address u, uint256 amount) public {
        vm.startPrank(u);
        IERC20(address(usdc)).approve(address(pool), amount);
        pool.repay(address(usdc), amount);
        vm.stopPrank();
    }

    function liquidate(address liq, address borrower, uint256 amount) public {
        vm.startPrank(liq);
        IERC20(address(usdc)).approve(address(pool), amount);
        pool.liquidate(borrower, address(usdc), address(weth), amount);
        vm.stopPrank();
    }
}
