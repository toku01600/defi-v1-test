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


interface IPriceOracle {
    function getPriceUSD(address asset) external view returns (int256 price, uint8 decimals);
}


/// @title PoolCore - 預入/借入/返済/清算 コア
contract PoolCore is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;


    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");


    struct AssetConfig {
        bool supported;
        uint16 collateralFactorBps; // 0-10000
        uint8 decimals; // token decimals
    }


    mapping(address => AssetConfig) public assetConfigs;
    address[] public listedAssets;


    IPriceOracle public oracle;
    address public safetyFund;


    uint16 public liquidatorIncentiveBps = 1000; // 10%
    uint16 public safetyFundBps = 500; // 5%


    mapping(address => mapping(address => uint256)) public deposits; // user=>asset=>amt
    mapping(address => mapping(address => uint256)) public borrows; // user=>asset=>amt


    mapping(address => uint256) public totalDeposits; // asset=>amt
    mapping(address => uint256) public totalBorrows; // asset=>amt

    // Events
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


    error NotSupported();
    error BadParam();
    error Unhealthy();
    error NoDebt();
    error OverWithdraw();


    constructor(address _oracle, address _safetyFund, address admin) {
        require(_oracle != address(0) && _safetyFund != address(0) && admin != address(0), "bad init");
        oracle = IPriceOracle(_oracle);
        safetyFund = _safetyFund;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        emit OracleUpdated(_oracle);
    emit SafetyFundUpdated(_safetyFund);
    }
    // --- Gov/Admin ---
    function listAsset(address asset, uint16 cfBps) external onlyRole(ADMIN_ROLE) {
        if (assetConfigs[asset].supported) revert BadParam();
        if (cfBps == 0 || cfBps > 10000) revert BadParam();
        uint8 decs = IERC20Metadata(asset).decimals();
        assetConfigs[asset] = AssetConfig({supported: true, collateralFactorBps: cfBps, decimals: decs});
        listedAssets.push(asset);
        emit AssetListed(asset, cfBps, decs);
    }


    function setCollateralFactor(address asset, uint16 newCfBps) external onlyRole(ADMIN_ROLE) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!cfg.supported) revert NotSupported();
        if (newCfBps == 0 || newCfBps > 10000) revert BadParam();
        uint16 old = cfg.collateralFactorBps;
        cfg.collateralFactorBps = newCfBps;
        emit CollateralFactorUpdated(asset, old, newCfBps);
    }


    function setFeeParams(uint16 _liqBps, uint16 _fundBps) external onlyRole(ADMIN_ROLE) {
        require(_liqBps + _fundBps <= 3000, "too high");
        liquidatorIncentiveBps = _liqBps;
        safetyFundBps = _fundBps;
        emit FeeParamsUpdated(_liqBps, _fundBps);
    }


    function setOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        require(_oracle != address(0), "zero oracle");
        oracle = IPriceOracle(_oracle);
        emit OracleUpdated(_oracle);
    }


    function setSafetyFund(address _safetyFund) external onlyRole(ADMIN_ROLE) {
        require(_safetyFund != address(0), "zero fund");
        safetyFund = _safetyFund;
        emit SafetyFundUpdated(_safetyFund);
    }
    
    // --- User actions ---
    function deposit(address asset, uint256 amount) external nonReentrant {
        AssetConfig memory cfg = _requireSupported(asset);
        if (amount == 0) revert BadParam();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][asset] += amount;
        totalDeposits[asset] += amount;
        emit Deposited(msg.sender, asset, amount);
    }


    function withdraw(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();
        uint256 bal = deposits[msg.sender][asset];
        if (amount > bal) revert OverWithdraw();


        deposits[msg.sender][asset] = bal - amount;
        totalDeposits[asset] -= amount;


        if (!_isHealthy(msg.sender)) {
            deposits[msg.sender][asset] = bal;
            totalDeposits[asset] += amount;
            revert Unhealthy();
        }


        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }
    function borrow(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();


        // プール流動性チェック（単純化）
        require(IERC20(asset).balanceOf(address(this)) >= amount, "illiquid");


        borrows[msg.sender][asset] += amount;
        totalBorrows[asset] += amount;
        if (!_isHealthy(msg.sender)) {
            borrows[msg.sender][asset] -= amount;
            totalBorrows[asset] -= amount;
            revert Unhealthy();
        }
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, asset, amount);
    }


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
        if (_isHealthy(borrower)) revert Unhealthy();


        uint256 pay = repayAmount > debt ? debt : repayAmount;
        IERC20(repayAsset).safeTransferFrom(msg.sender, address(this), pay);


        (uint256 repayPrice, uint8 rpDec) = _priceUSD(repayAsset);
        (uint256 colPrice, uint8 cpDec) = _priceUSD(collateralAsset);


        uint256 repayValueUSD = pay * repayPrice / (10 ** rpDec);
        uint256 multiplierBps = 10000 + liquidatorIncentiveBps + safetyFundBps;
        uint256 seizeValueUSD = repayValueUSD * multiplierBps / 10000;
        uint256 seizeAmount = seizeValueUSD * (10 ** cpDec) / colPrice;


        uint256 userColBal = deposits[borrower][collateralAsset];
        require(userColBal >= seizeAmount, "insufficient collateral");
        deposits[borrower][collateralAsset] = userColBal - seizeAmount;
        totalDeposits[collateralAsset] -= seizeAmount;


        uint256 toLiq = seizeAmount * liquidatorIncentiveBps / multiplierBps;
        uint256 toFund = seizeAmount * safetyFundBps / multiplierBps;
        uint256 toPool = seizeAmount - toLiq - toFund; // プール内残高


        borrows[borrower][repayAsset] = debt - pay;
        totalBorrows[repayAsset] -= pay;


        IERC20(collateralAsset).safeTransfer(msg.sender, toLiq);
        IERC20(collateralAsset).safeTransfer(safetyFund, toFund);
        // toPool はコントラクト内に残す


        emit Liquidated(borrower, repayAsset, collateralAsset, pay, seizeAmount, msg.sender);
    }
    // --- Views ---
    function isHealthy(address user) external view returns (bool) { return _isHealthy(user); }


    function utilization(address asset) external view returns (uint256 bps) {
        uint256 dep = totalDeposits[asset];
        uint256 bor = totalBorrows[asset];
        if (dep == 0) return 0; return bor * 10000 / dep;
    }


    function getListedAssets() external view returns (address[] memory) { return listedAssets; }


    // --- Internals ---
    function _requireSupported(address asset) internal view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset]; if (!cfg.supported) revert NotSupported();
    }


    function _isHealthy(address user) internal view returns (bool) {
        (uint256 colUSD, uint256 borUSD) = getUserAccountValuesUSD(user);
        return borUSD <= colUSD;
    }


    function getUserAccountValuesUSD(address user) public view returns (uint256 collateralUSD, uint256 borrowUSD) {
        for (uint256 i=0; i<listedAssets.length; i++) {
            address asset = listedAssets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.supported) continue;
            (uint256 px, uint8 pd) = _priceUSD(asset);
            uint256 dep = deposits[user][asset];
            uint256 bor = borrows[user][asset];
            if (dep > 0) {
                uint256 v = dep * px / (10 ** pd);
                collateralUSD += v * cfg.collateralFactorBps / 10000;
            }
            if (bor > 0) {
                uint256 v2 = bor * px / (10 ** pd);
                borrowUSD += v2;
            }
        }
    }

    function _priceUSD(address asset) internal view returns (uint256 price, uint8 decs) {
        (int256 p, uint8 d) = oracle.getPriceUSD(asset);
        require(p > 0, "bad price");
        return (uint256(p), d);
    }
}