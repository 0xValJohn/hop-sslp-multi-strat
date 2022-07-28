// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/Hop/ISwap.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

// ---------------------- STATE VARIABLES ----------------------
    
    IERC20 public constant WETH_LP = IERC20(0x59745774Ed5EfF903e615F5A2282Cae03484985a);
    ISwap public hop = ISwap(0x652d27c0F72771Ce5C76fd400edD61B406Ac6D97);
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 public maxSlippage;  

// ---------------------- CONSTRUCTOR ----------------------

    constructor(
        address _vault
    ) public BaseStrategy(_vault) {
         _initializeStrat();
    }

    function _initializeStrat() internal {
        maxSlippage = 30;
    }

    function name() external view override returns (string memory) {
        return "StrategyHopSslpETH";
    }

// ---------------------- MAIN ----------------------

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + valueLpToWant();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
            _loss = 0;
        } else {
            _loss = _totalDebt - _totalAssets;
            _profit = 0;
        }
        _debtPayment = _debtOutstanding;

        // free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _liquidWant = balanceOfWant();
        uint256 _toFree = _debtOutstanding + _profit;

        // liquidate some of the Want
        if (_liquidWant < _toFree) {
            // liquidation can result in a profit depending on pool balance
            (uint256 _liquidationProfit, uint256 _liquidationLoss) = _removeliquidity(_toFree);
            // update the P&L to account for liquidation
            _loss = _loss + _liquidationLoss;
            _profit = _profit + _liquidationProfit;
            _liquidWant = balanceOfWant();

            // Case 1 - enough to pay profit (or some) only
            if (_liquidWant <= _profit) {
                _profit = _liquidWant;
                _debtPayment = 0;
            // Case 2 - enough to pay _profit and _debtOutstanding
            // Case 3 - enough to pay for all profit, and some _debtOutstanding
            } else {
                _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
            }
        }
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant(); 
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest = _liquidWant - _debtOutstanding;
            _addLiquidity(_amountToInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant < _amountNeeded) {
            _removeliquidity(_amountNeeded);
        } else {
            return (_amountNeeded, 0);
        }
        _liquidWant = balanceOfWant();
        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _lpTokenAmount = WETH_LP.balanceOf(address(this));
        uint256 _amountToLiquidate = _calculateRemoveLiquidityOneToken(_lpTokenAmount);
        _removeliquidity(_amountToLiquidate);
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
    // nothing to do here, there is no non-want token!
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    // ---------------------- MANAGEMENT FUNCTIONS ----------------------

    function setMaxSlippage(uint256 _maxSlippage)
        external
        onlyVaultManagers
    {
        maxSlippage = _maxSlippage;
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    // To deposit to Hop, we need to create an array of uints that tells Hop how much of each asset we want to deposit.
    // If we were to deposit 100 WETH e.g., we would pass [100, 0] (forget decimals for simplicity). note: wtoken is always index 0

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantAmount;
        uint256 _minToMint = hop.calculateTokenAmount(address(this), _amountsToAdd, true);
        uint256 _deadline = block.timestamp + 10 minutes;
        uint256 _priceImpact = (_minToMint * hop.getVirtualPrice() - _wantAmount) / _wantAmount * MAX_BIPS;
        if (_priceImpact > maxSlippage) {
            return;
        } else {
            hop.addLiquidity(_amountsToAdd, _minToMint, _deadline);
        }
    }

    function _removeliquidity(uint256 _wantAmount) internal returns (uint256 _liquidationProfit, uint256 _liquidationLoss) {
        uint256[] memory _amountsToRemove = new uint256[](2);
        _amountsToRemove[0] = _wantAmount;
        uint256 _estimatedTotalAssetsBefore = estimatedTotalAssets();
        uint256 _minToMint = hop.calculateTokenAmount(address(this), _amountsToRemove, false);
        uint256 _deadline = block.timestamp + 10 minutes;
        hop.removeLiquidityOneToken(_wantAmount, 0, _minToMint, _deadline);
        uint256 _estimatedTotalAssetsAfter = estimatedTotalAssets();
        if (_estimatedTotalAssetsAfter >= _estimatedTotalAssetsBefore) {
            return (_estimatedTotalAssetsAfter - _estimatedTotalAssetsBefore, 0);
        } else { 
            return (0, _estimatedTotalAssetsBefore - _estimatedTotalAssetsAfter);
        }
    }

    function _calculateRemoveLiquidityOneToken(uint256 _lpTokenAmount) public view returns (uint256) {
        return hop.calculateRemoveLiquidityOneToken(address(this), _lpTokenAmount, 0);
    }

    function valueLpToWant() public view returns (uint256) {
        uint256 _lpTokenAmount = WETH_LP.balanceOf(address(this));
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _lpTokenAmount;
        return hop.calculateTokenAmount(address(this), _amounts, false);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }
}