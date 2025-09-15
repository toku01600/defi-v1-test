// =============================================
// src/PoolCore.sol
// =============================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";


/// @title PoolCore - Lending/Borrowing Core Contract
/// @notice Handles deposits, borrows, repayments, and liquidations
/// @dev 預入・借入・返済・清算を管理するコアコントラクト
/// Security: Designed with nonReentrant guards, SafeERC20, and strict accounting
contract PoolCore is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Structs ---
    struct AssetConfig {
        bool supported;
        uint16 collateralFactorBps; // 0-10000
        uint8 decimals; // token decimals
    }

    // --- State ---
    mapping(address => AssetConfig) public assetConfigs;
    address[] public listedAssets;

    IPriceOracle public oracle;
    address public safetyFund;

    uint16 public liquidatorIncentiveBps = 1000; // 10%
    uint16 public safetyFundBps = 500; // 5%

    // User balances / ユーザー毎の残高
    mapping(address => mapping(address => uint256)) public deposits; // user=>asset=>amt
    mapping(address => mapping(address => uint256)) public borrows; // user=>asset=>amt

    // Pool totals / プール全体の残高
    mapping(address => uint256) public totalDeposits; // asset=>amt
    mapping(address => uint256) public totalBorrows; // asset=>amt

    // --- event ---
    event AssetListed(address indexed asset, uint16 cfBps, uint8 decimals);
    event CollateralFactorUpdated(address indexed asset, uint16 oldCfBps, uint16 newCfBps);
    event OracleUpdated(address indexed oracle);
    event SafetyFundUpdated(address indexed safetyFund);
    event FeeParamsUpdated(uint16 liquidatorIncentiveBps, uint16 safetyFundBps);

    event Deposited(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount);
    event Repaid(address indexed user, address indexed asset, uint256 amount);
    event Liquidated(
        address indexed borrower,
        address indexed repayAsset,
        address indexed collateralAsset,
        uint256 repayAmount,
        uint256 collateralSeized,
        address liquidator
    );

    // --- Errors ---
    error NotSupported();
    error BadParam();
    error Unhealthy();
    error NoDebt();
    error OverWithdraw();
    error NotHealthy();
    error InsufficientCollateral();

    // --- Constructor ---
    /// @param _oracle Price oracle contract / オラクルコントラクト
    /// @param _safetyFund Safety fund address / セーフティファンドアドレス
    /// @param admin Admin address / 管理者アドレス
    constructor(address _oracle, address _safetyFund, address admin) {
        require(_oracle != address(0) && _safetyFund != address(0) && admin != address(0), "bad init");
        oracle = IPriceOracle(_oracle);
        safetyFund = _safetyFund;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        emit OracleUpdated(_oracle);
        emit SafetyFundUpdated(_safetyFund);
    }
    
    // ============================================================
    // Admin Functions / 管理者機能
    // ============================================================

    /// @notice Register a new supported asset
    /// @dev 新しい担保資産を登録する
    function listAsset(address asset, uint16 cfBps) external onlyRole(ADMIN_ROLE) {
        if (assetConfigs[asset].supported) revert BadParam();
        if (cfBps == 0 || cfBps > 10000) revert BadParam();
        uint8 decs = IERC20Metadata(asset).decimals();
        assetConfigs[asset] = AssetConfig({supported: true, collateralFactorBps: cfBps, decimals: decs});
        listedAssets.push(asset);
        emit AssetListed(asset, cfBps, decs);
    }

    /// @notice Update collateral factor for an asset
    /// @dev 指定資産の担保係数を更新する
    function setCollateralFactor(address asset, uint16 newCfBps) external onlyRole(ADMIN_ROLE) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!cfg.supported) revert NotSupported();
        if (newCfBps == 0 || newCfBps > 10000) revert BadParam();
        uint16 old = cfg.collateralFactorBps;
        cfg.collateralFactorBps = newCfBps;
        emit CollateralFactorUpdated(asset, old, newCfBps);
    }

    /// @notice Update liquidation incentive and safety fund fee
    /// @dev 清算報酬とセーフティファンド手数料を更新する
    function setFeeParams(uint16 _liqBps, uint16 _fundBps) external onlyRole(ADMIN_ROLE) {
        require(_liqBps + _fundBps <= 3000, "too high");
        liquidatorIncentiveBps = _liqBps;
        safetyFundBps = _fundBps;
        emit FeeParamsUpdated(_liqBps, _fundBps);
    }

    /// @notice Set oracle contract
    /// @dev オラクルコントラクトを設定
    function setOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        require(_oracle != address(0), "zero oracle");
        oracle = IPriceOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    /// @notice Set safety fund address
    /// @dev セーフティファンドアドレスを設定
    function setSafetyFund(address _safetyFund) external onlyRole(ADMIN_ROLE) {
        require(_safetyFund != address(0), "zero fund");
        safetyFund = _safetyFund;
        emit SafetyFundUpdated(_safetyFund);
    }
    
    // ============================================================
    // User Functions / ユーザー操作
    // ============================================================

    /// @notice Deposit collateral into the pool
    /// @dev ユーザーが資産をプールに預け入れる
    function deposit(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][asset] += amount;
        totalDeposits[asset] += amount;
        emit Deposited(msg.sender, asset, amount);
    }

    /// @notice Withdraw collateral
    /// @dev 預入資産を引き出す（引出後も健全性を維持する必要あり）
    function withdraw(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "invalid amount");
        require(deposits[msg.sender][asset] >= amount, "not enough balance");

        deposits[msg.sender][asset] -= amount;

        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(msg.sender);
        require(colUsd >= borUsd, "Not healthy after withdraw");

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }

    /// @notice Borrow asset from the pool
    /// @dev プールから資産を借入する
    function borrow(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();

        borrows[msg.sender][asset] += amount;
        totalBorrows[asset] += amount;

        if (!isHealthy(msg.sender)) {
            borrows[msg.sender][asset] -= amount;
            totalBorrows[asset] -= amount;
            revert NotHealthy();
        }

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, asset, amount);
    }

    /// @notice Repay borrowed asset
    /// @dev 借入資産を返済する
    function repay(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();
        uint256 debt = borrows[msg.sender][asset];
        if (debt == 0) revert NoDebt();
        uint256 pay = amount > debt ? debt : amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), pay);
        borrows[msg.sender][asset] = debt - pay;
        totalBorrows[asset] -= pay;
        emit Repaid(msg.sender, asset, pay);
    }
    
    /// @notice Liquidate unhealthy accounts
    /// @dev 健全性を失ったアカウントを清算する
    function liquidate(
        address borrower,
        address repayAsset,
        address collateralAsset,
        uint256 repayAmount
    ) external nonReentrant {
        if (borrower == address(0) || repayAmount == 0) revert BadParam();
        _requireSupported(repayAsset);
        _requireSupported(collateralAsset);

        uint256 debt = borrows[borrower][repayAsset];
        if (debt == 0) revert NoDebt();
        if (isHealthy(borrower)) revert Unhealthy();

        uint256 pay = repayAmount > debt ? debt : repayAmount;
        IERC20(repayAsset).safeTransferFrom(msg.sender, address(this), pay);

        uint256 repayPx18 = _priceUsd1e18(repayAsset);
        uint256 colPx18   = _priceUsd1e18(collateralAsset);

        uint8 repayDecs = assetConfigs[repayAsset].decimals;
        uint8 colDecs   = assetConfigs[collateralAsset].decimals;

        uint256 repayValueUsd = pay * repayPx18 / (10 ** repayDecs);
        uint256 multiplierBps = 10000 + liquidatorIncentiveBps + safetyFundBps;
        uint256 seizeValueUsd = repayValueUsd * multiplierBps / 10000;

        uint256 seizeAmount = seizeValueUsd * (10 ** colDecs) / colPx18;
        uint256 userColBal = deposits[borrower][collateralAsset];
        
        if (seizeAmount > userColBal) seizeAmount = userColBal;
        
        deposits[borrower][collateralAsset] = userColBal - seizeAmount;
        totalDeposits[collateralAsset] -= seizeAmount;

        uint256 toLiq = seizeAmount * liquidatorIncentiveBps / multiplierBps;
        uint256 toFund = seizeAmount * safetyFundBps / multiplierBps;
        
        borrows[borrower][repayAsset] = debt - pay;
        totalBorrows[repayAsset] -= pay;

        IERC20(collateralAsset).safeTransfer(msg.sender, toLiq);
        IERC20(collateralAsset).safeTransfer(safetyFund, toFund);

        emit Liquidated(borrower, repayAsset, collateralAsset, pay, seizeAmount, msg.sender);
    }

    // ============================================================
    // View Functions / ビュー関数
    // ============================================================

    /// @notice Check if account is healthy
    /// @dev アカウントが健全かどうか確認する
    function isHealthy(address user) public view returns (bool) {
        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(user);
        return colUsd >= borUsd;
    }

    /// @notice Check if account can be liquidated
    /// @dev 清算可能かどうかを確認する
    function canBeLiquidated(address user) public view returns (bool) {
        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(user);
        return colUsd < borUsd;
    }

    /// @notice Utilization ratio of an asset
    /// @dev アセット利用率を返す
    function utilization(address asset) external view returns (uint256 bps) {
        uint256 dep = totalDeposits[asset];
        uint256 bor = totalBorrows[asset];
        if (dep == 0) return 0;
        return bor * 10000 / dep;
    }

    /// @notice List all registered assets
    /// @dev 登録済み資産一覧を返す
    function getListedAssets() external view returns (address[] memory) { 
        return listedAssets; 
    }

    /// @notice Get raw collateral & borrow values (without collateral factor)
    /// @dev 生の担保額・借入額をUSD換算で返す（担保係数は未適用）
    function getUserTotalsUsd(address user) public view returns (uint256 collateralUsdRaw, uint256 borrowUsd) {
        for (uint256 i=0; i<listedAssets.length; i++) {
            address asset = listedAssets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.supported) continue;

            uint256 price18 = _priceUsd1e18(asset);
            uint8 tokDec = cfg.decimals;

            uint256 dep = deposits[user][asset];
            uint256 bor = borrows[user][asset];

            if (dep > 0) {
                collateralUsdRaw += dep * price18 / (10 ** tokDec);
            }
            if (bor > 0) {
                borrowUsd += bor * price18 / (10 ** tokDec);
            }
        }
    }

    /// @notice Get collateral & borrow values (with collateral factor applied)
    /// @dev 担保係数を考慮した担保額・借入額を返す
    function getUserAccountValuesUsd(address user) public view returns (uint256 collateralUsd, uint256 borrowUsd) {
        for (uint256 i = 0; i < listedAssets.length; i++) {
            address asset = listedAssets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.supported) continue;

            uint256 price18 = _priceUsd1e18(asset);

            uint256 dep = deposits[user][asset];
            uint256 bor = borrows[user][asset];

            if (dep > 0) {
                uint256 v = dep * price18 / (10 ** cfg.decimals);
                collateralUsd += v * cfg.collateralFactorBps / 10000;
            }
            if (bor > 0) {
                uint256 v2 = bor * price18 / (10 ** cfg.decimals);
                borrowUsd += v2;
            }
        }
    }

    // ============================================================
    // Internal Utilities / 内部関数
    // ============================================================

    /// @dev Require asset to be supported
    function _requireSupported(address asset) internal view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset];
        if (!cfg.supported) revert NotSupported();
    }

    /// @dev Convert oracle price to 1e18 scale
    function _priceUsd1e18(address asset) internal view returns (uint256) {
        (int256 rawPrice, uint8 decimals) = oracle.getPriceUsd(asset);
        require(rawPrice > 0, "bad price");

        uint256 price = uint256(rawPrice);

        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        } else {
            return price;
        }
    }
}
