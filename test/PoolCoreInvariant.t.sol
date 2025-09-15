// =============================================
// test/PoolCoreInvariant.t.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {PoolCore} from "../src/PoolCore.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolCoreHandler} from "./helpers/PoolCoreHandler.sol";

contract PoolCoreInvariantTest is StdInvariant, Test {
    PoolCore public pool;
    MockOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public weth;
    PoolCoreHandler public handler;

    address public safetyFund = address(0xBEEF);

    address[] public users;

    function setUp() public {
        // --- users ---
        uint256 numUsers = 5;
        users = new address[](numUsers);
        for (uint i = 0; i < numUsers; i++) {
            users[i] = address(uint160(i + 1));
        }

        // --- deploy mocks ---
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new MockOracle();

        // set initial prices (MockOracle.setPrice(asset, price, decimals))
        // (use 8 decimals for feed-like behavior)
        oracle.setPrice(address(usdc), int256(1e8), 8);       // USDC = $1.00 (1e8 with 8 decimals)
        oracle.setPrice(address(weth), int256(2000e8), 8);    // WETH = $2000

        // --- deploy PoolCore ---
        // note: constructor: (address _oracle, address _safetyFund, address _admin)
        address admin = address(this);
        pool = new PoolCore(address(oracle), safetyFund, admin);

        // As constructor only granted DEFAULT_ADMIN_ROLE to _admin, give ADMIN_ROLE to admin
        // so that this test contract can call listAsset (listAsset requires onlyRole(ADMIN_ROLE))
        pool.grantRole(pool.ADMIN_ROLE(), admin);

        // --- list assets (must be called by ADMIN_ROLE) ---
        pool.listAsset(address(usdc), 9000); // USDC cf = 90%
        pool.listAsset(address(weth), 8000); // WETH cf = 80%

        // --- mint balances to users ---
        for (uint i = 0; i < numUsers; i++) {
            usdc.mint(users[i], 1_000_000e6); // 1,000,000 USDC (6 decimals)
            weth.mint(users[i], 100e18);      // 100 WETH
        }

        // --- handler ---
        handler = new PoolCoreHandler(pool, usdc, weth, users);

        // optional: allow handler to act as ADMIN if you later want it to call admin functions
        // pool.grantRole(pool.ADMIN_ROLE(), address(handler));

        // register handler as target for invariant fuzzing
        targetContract(address(handler));

        // labels for easier debugging output
        vm.label(address(pool), "PoolCore");
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
        vm.label(address(oracle), "MockOracle");
        vm.label(safetyFund, "SafetyFund");
    }

    // ========== invariants ==========

    // existing invariant: pool totals
    function invariant_totalDepositsGTEBorrows() public view {
        assertGe(pool.totalDeposits(address(usdc)), pool.totalBorrows(address(usdc)));
        assertGe(pool.totalDeposits(address(weth)), pool.totalBorrows(address(weth)));
    }

    // deposit / withdraw consistency
    function invariant_depositWithdraw_consistency() public view {
        uint256 poolUsdcBal = usdc.balanceOf(address(pool));
        uint256 poolWethBal = weth.balanceOf(address(pool));

        // pool balances must be at least totalDeposits - totalBorrows (simple liquidity check)
        // note: since some transfers (liquidation payouts) may change balances,
        // this is a conservative assert (>=)
        assertGe(poolUsdcBal, pool.totalDeposits(address(usdc)) - pool.totalBorrows(address(usdc)));
        assertGe(poolWethBal, pool.totalDeposits(address(weth)) - pool.totalBorrows(address(weth)));
    }

    // NEW: user solvent invariant — each user's collateral (with cf applied) >= borrow
    function invariant_usersSolvent() public view {
        for (uint i = 0; i < users.length; i++) {
            address u = users[i];
            (uint256 collateralUsd, uint256 borrowUsd) = pool.getUserAccountValuesUsd(u);
            // collateralUsd already has collateral factor applied in PoolCore.getUserAccountValuesUsd
            // enforce collateral >= borrow
            assertGe(collateralUsd, borrowUsd);
        }
    }
}
