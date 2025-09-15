// =============================================
// test/helpers/PoolCoreHandlerFuzz.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/PoolCore.sol";   
import "../mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract PoolCoreHandlerFuzz {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    PoolCore public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    address[] public users;

    constructor(PoolCore _pool, MockERC20 _usdc, MockERC20 _weth, address[] memory _users) {
        pool = _pool;
        usdc = _usdc;
        weth = _weth;
        users = _users;
    }

    function randomOperation(uint256 seed) public {
        address u = users[seed % users.length];
        uint256 op = seed % 5;

        if (op == 0) try this._deposit(u, seed % 1_000_000e6) {} catch {}
        if (op == 1) try this._withdraw(u, seed % 100e6) {} catch {}
        if (op == 2) try this._borrow(u, seed % 500_000e6) {} catch {}
        if (op == 3) try this._repay(u, seed % 500_000e6) {} catch {}
        if (op == 4) try this._liquidate(u, users[(seed+1) % users.length], seed % 500_000e6) {} catch {}
    }

    function _deposit(address u, uint256 amount) public {
        IERC20(address(usdc)).approve(address(pool), amount);
        pool.deposit(address(usdc), amount);
    }

    function _withdraw(address u, uint256 amount) public {
        pool.withdraw(address(usdc), amount);
    }

    function _borrow(address u, uint256 amount) public {
        pool.borrow(address(usdc), amount);
    }

    function _repay(address u, uint256 amount) public {
        IERC20(address(usdc)).approve(address(pool), amount);
        pool.repay(address(usdc), amount);
    }

    function _liquidate(address liq, address borrower, uint256 amount) public {
        IERC20(address(usdc)).approve(address(pool), amount);
        pool.liquidate(borrower, address(usdc), address(weth), amount);
    }
}
