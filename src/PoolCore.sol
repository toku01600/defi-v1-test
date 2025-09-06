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
    error NotHealthy();
    error InsufficientCollateral();

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
        // AssetConfig memory cfg = _requireSupported(asset);
        _requireSupported(asset);
        if (amount == 0) revert BadParam();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][asset] += amount;
        totalDeposits[asset] += amount;
        emit Deposited(msg.sender, asset, amount);
    }


    function withdraw(address asset, uint256 amount) external {
        require(amount > 0, "invalid amount");
        require(deposits[msg.sender][asset] >= amount, "not enough balance");

        deposits[msg.sender][asset] -= amount;

        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(msg.sender);
        require(colUsd >= borUsd, "Not healthy after withdraw");

        IERC20(asset).transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }



    
    function borrow(address asset, uint256 amount) external nonReentrant {
        _requireSupported(asset);
        if (amount == 0) revert BadParam();

        borrows[msg.sender][asset] += amount;
        totalBorrows[asset] += amount;

        if (!isHealthy(msg.sender)) {
            // rollback
            borrows[msg.sender][asset] -= amount;
            totalBorrows[asset] -= amount;
            revert NotHealthy();
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
        if (isHealthy(borrower)) revert Unhealthy();

        uint256 pay = repayAmount > debt ? debt : repayAmount;
        IERC20(repayAsset).safeTransferFrom(msg.sender, address(this), pay);

        // 新しい 1e18 スケールの価格取得
        uint256 repayPx18 = _priceUsd1e18(repayAsset);
        uint256 colPx18   = _priceUsd1e18(collateralAsset);

        uint8 repayDecs = assetConfigs[repayAsset].decimals;
        uint8 colDecs   = assetConfigs[collateralAsset].decimals;

        // USD換算 (常に1e18スケール)
        uint256 repayValueUsd = pay * repayPx18 / (10 ** repayDecs);

        uint256 multiplierBps = 10000 + liquidatorIncentiveBps + safetyFundBps;
        uint256 seizeValueUsd = repayValueUsd * multiplierBps / 10000;

        // seizeAmount = 必要担保量（トークン単位）
        // USD(1e18) → トークン = USD * 10^tokenDecimals / price(1e18)
        uint256 seizeAmount = seizeValueUsd * (10 ** colDecs) / colPx18;

        uint256 userColBal = deposits[borrower][collateralAsset];
        // clamp: ユーザー担保残高を超えないように調整
        if (seizeAmount > userColBal) {
        seizeAmount = userColBal;
    }

    deposits[borrower][collateralAsset] = userColBal - seizeAmount;
        totalDeposits[collateralAsset] -= seizeAmount;

        uint256 toLiq = seizeAmount * liquidatorIncentiveBps / multiplierBps;
        uint256 toFund = seizeAmount * safetyFundBps / multiplierBps;
        // toPool = seizeAmount - toLiq - toFund; // プール残し (コメントアウト可)

        borrows[borrower][repayAsset] = debt - pay;
        totalBorrows[repayAsset] -= pay;

        IERC20(collateralAsset).safeTransfer(msg.sender, toLiq);
        IERC20(collateralAsset).safeTransfer(safetyFund, toFund);

        emit Liquidated(borrower, repayAsset, collateralAsset, pay, seizeAmount, msg.sender);
    }

    function isHealthy(address user) public view returns (bool) {
        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(user);
        return colUsd >= borUsd;
    }

    function canBeLiquidated(address user) public view returns (bool) {
        (uint256 colUsd, uint256 borUsd) = getUserAccountValuesUsd(user);
        return colUsd < borUsd; // or use liquidationThresholdBps
    }



    function utilization(address asset) external view returns (uint256 bps) {
        uint256 dep = totalDeposits[asset];
        uint256 bor = totalBorrows[asset];
        if (dep == 0) return 0;
        return bor * 10000 / dep;
    }


    function getListedAssets() external view returns (address[] memory) { return listedAssets; }


    // --- Internals ---
    function _requireSupported(address asset) internal view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset];
        if (!cfg.supported) revert NotSupported();
    }


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

    function getUserAccountValuesUsd(address user) public view returns (uint256 collateralUsd, uint256 borrowUsd) {
        for (uint256 i = 0; i < listedAssets.length; i++) {
            address asset = listedAssets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.supported) continue;

            //  必ず _priceUsd1e18 を使って統一スケールにする
            uint256 price18 = _priceUsd1e18(asset);

            uint256 dep = deposits[user][asset];
            uint256 bor = borrows[user][asset];

            if (dep > 0) {
                // 担保 = tokenAmount * price / 10^decimals
                uint256 v = dep * price18 / (10 ** cfg.decimals);
                collateralUsd += v * cfg.collateralFactorBps / 10000;
            }
            if (bor > 0) {
                uint256 v2 = bor * price18 / (10 ** cfg.decimals);
                borrowUsd += v2;
            }
        }
    }



    function _priceUsd1e18(address asset) internal view returns (uint256) {
        (int256 rawPrice, uint8 decimals) = oracle.getPriceUsd(asset);
        require(rawPrice > 0, "bad price");

        uint256 price = uint256(rawPrice);

        // 価格を 1e18 スケールに統一
        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        } else {
            return price;
        }
    }
}