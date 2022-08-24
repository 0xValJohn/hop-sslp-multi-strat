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
    
    IERC20 public wantLp;
    ISwap public hopISwap;
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals;
    uint256 public maxSlippage;  

// ---------------------- CONSTRUCTOR ----------------------

    constructor(
        address _vault
    ) public BaseStrategy(_vault) {
         _initializeStrat();
    }

    function _initializeStrat() internal {
        maxSlippage = 30;
        wantLp = IERC20(0x59745774Ed5EfF903e615F5A2282Cae03484985a);
        hopISwap = ISwap(0x652d27c0F72771Ce5C76fd400edD61B406Ac6D97);
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

// ---------------------- CLONING ----------------------
    event Cloned(address indexed clone);
    bool public isOriginal = true;

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        IERC20 _wantLp,
        ISwap _hopISwap
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        maxSlippage = _maxSlippage;
        wantLp = _wantLp;
        hopISwap = _hopISwap;
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

    function cloneHop(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        IERC20 _wantLp,
        ISwap _hopISwap
        ) external returns (address newStrategy) {
            require(isOriginal, "!clone");
            bytes20 addressBytes = bytes20(address(this));

            assembly {
                // EIP-1167 bytecode
                let clone_code := mload(0x40)
                mstore(
                    clone_code,
                    0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
                )
                mstore(add(clone_code, 0x14), addressBytes)
                mstore(
                    add(clone_code, 0x28),
                    0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
                )
                newStrategy := create(0, clone_code, 0x37)
            }

            Strategy(newStrategy).initialize(
                _vault,
                _strategist,
                _rewards,
                _keeper,
                _maxSlippage,
                _wantLp,
                _hopISwap
            );

            emit Cloned(newStrategy);
        }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyHopSslp",
                    IERC20Metadata(address(want)).symbol()
                )
            );
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
        }    
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
        // Final accounting for P&L and debt payment
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
            _removeliquidity(_amountNeeded - _liquidWant);
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
        uint256 _lpTokenAmount = wantLp.balanceOf(address(this));
        uint256 _amountToLiquidate = (_lpTokenAmount * hopISwap.getVirtualPrice())/1e18;
        _removeliquidity(_amountToLiquidate);
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        _checkAllowance(_newStrategy, address(want), want.balanceOf(address(this)));
        want.transfer(_newStrategy, balanceOfWant());
        _checkAllowance(_newStrategy, address(wantLp), wantLp.balanceOf(address(this))); //TODO: check if required
        wantLp.transfer(_newStrategy, wantLp.balanceOf(address(this)));
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

    // To add liq, create an array of uints for how much of each asset we want to deposit
    // e.g. for 100 WETH, we would pass [100, 0], wtoken is always index 0

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2); 
        _amountsToAdd[0] = _wantAmount;
        uint256 _wantInLpToken = _wantAmount * wantDecimals / hopISwap.getVirtualPrice();
        // enforcing slippage protection
        uint256 _expectedLpToMint = hopISwap.calculateTokenAmount(address(this), _amountsToAdd, true);
        uint256 _mintLpToMint = _wantInLpToken - (_wantInLpToken  * maxSlippage) / MAX_BIPS;
        if (_expectedLpToMint < _mintLpToMint) {
            return; // we revert if slippage test fails
        } else {
            uint256 _deadline = block.timestamp;
            _checkAllowance(address(hopISwap), address(want), _wantAmount); 
            /** 
            * @param amounts the amounts of each token to add, in their native precision
            * @param minToMint the minimum LP tokens adding this amount of liquidity
            */
            hopISwap.addLiquidity(_amountsToAdd, _mintLpToMint, _deadline);
        }
    }

    function _removeliquidity(uint256 _wantAmount) internal returns (uint256 _liquidationProfit, uint256 _liquidationLoss) {
        uint256 _amountsToRemove = Math.min(_wantAmount * wantDecimals / hopISwap.getVirtualPrice(), wantLp.balanceOf(address(this)));
        uint256 _estimatedTotalAssetsBefore = estimatedTotalAssets();
        uint256 _expectedMinWantAmount = _calculateRemoveLiquidityOneToken(_amountsToRemove);
        uint256 _minWantOut = _wantAmount - (_wantAmount * maxSlippage) / MAX_BIPS;
        // enforcing slippage protection
       if (_expectedMinWantAmount < _minWantOut) {
            return (0,0);
        } else {
            uint256 _deadline = block.timestamp;
            _checkAllowance(address(hopISwap), address(wantLp), _amountsToRemove); 
            /**
            * @param tokenAmount the amount of the LP token you want to receive
            * @param tokenIndex the index of the token you want to receive
            * @param minAmount the minimum amount to withdraw, otherwise revert
            */
            hopISwap.removeLiquidityOneToken(_amountsToRemove, 0, _minWantOut, _deadline);
            uint256 _estimatedTotalAssetsAfter = estimatedTotalAssets();
            // depending on the reserves balances, there will be a positive or negative price impact
            if (_estimatedTotalAssetsAfter >= _estimatedTotalAssetsBefore) {
                // remove liq  resulted in a profit
                return (_estimatedTotalAssetsAfter - _estimatedTotalAssetsBefore, 0);
            } else { 
                // remove liq resulted in a loss
                return (0, _estimatedTotalAssetsBefore - _estimatedTotalAssetsAfter);
            }
        }
    }

    function _calculateRemoveLiquidityOneToken(uint256 _lpTokenAmount) public view returns (uint256) {
        return hopISwap.calculateRemoveLiquidityOneToken(address(this), _lpTokenAmount, 0);
    }

    // using virtual price (pool_reserves/lp_supply) to estimate LP token value
    function valueLpToWant() public view returns (uint256) {
        uint256 _lpTokenAmount = wantLp.balanceOf(address(this));
        uint256 _valueLpToWant = (_lpTokenAmount * hopISwap.getVirtualPrice())/1e18;
        return _valueLpToWant;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }
}