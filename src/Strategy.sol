// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// Core libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/Hop/ISwap.sol";
import "./interfaces/Hop/IStakingRewards.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

// ---------------------- STATE VARIABLES ----------------------

    uint256 private constant max = type(uint256).max;
    address public tradeFactory;
    uint256 public maxSlippage;
    IERC20 public lpToken;
    IERC20 public emissionToken;
    ISwap public lpContract;
    IStakingRewards public lpStaker;

    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals;

// ---------------------- CONSTRUCTOR ----------------------

    constructor(
        address _vault,
        uint256 _maxSlippage,
        address _lpToken,
        address _emissionToken,
        address _lpContract,
        address _lpStaker
    ) public BaseStrategy(_vault) {
        _initializeStrat(_maxSlippage, _lpToken, _emissionToken, _lpContract, _lpStaker);
    }

    function _initializeStrat(
        uint256 _maxSlippage,
        address _lpToken,
        address _emissionToken,
        address _lpContract,
        address _lpStaker
    ) internal {
        maxSlippage = _maxSlippage;
        lpToken = IERC20(_lpToken);
        emissionToken = IERC20(_emissionToken);
        lpContract = ISwap(_lpContract);
        lpStaker = IStakingRewards(_lpStaker);
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
        address _lpToken,
        address _emissionToken,
        address _lpContract,
        address _lpStaker
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_maxSlippage, _lpToken, _emissionToken, _lpContract, _lpStaker);
    }

    function cloneHop(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        address _lpToken,
        address _emissionToken,
        address _lpContract,
        address _lpStaker
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }
        Strategy(newStrategy).initialize(
            _vault, _strategist, _rewards, _keeper, _maxSlippage, _lpToken, _emissionToken, _lpContract, _lpStaker
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyHopSslp", IERC20Metadata(address(want)).symbol()));
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
        _claimRewards();

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

        // liquidate some of the want
        if (_liquidWant < _toFree) {
            // liquidation can result in a profit depending on pool balance (slippage)
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

        // enough to pay profit (partial or full) only
        if (_liquidWant <= _profit) {
            _profit = _liquidWant;
            _debtPayment = 0;

            // enough to pay for all profit and _debtOutstanding (partial or full)
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
        // if we had to remove liquidity, look at the updated balanceOfWant
        _liquidWant = balanceOfWant();
        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _unstakeAll();
        if (balanceOfUnstakedLPToken() > 0) {
            _removeliquidity(balanceOfUnstakedLPToken());
        }
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeAll();
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
    }

// ---------------------- KEEP3RS ----------------------

    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth) public view override returns (bool) {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp - params.lastReport > maxReportDelay) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        if (block.timestamp - params.lastReport > minReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    // convert our keeper's eth cost into want, we don't need this anymore since we override the baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

// ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        emissionToken.safeApprove(_tradeFactory, max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(emissionToken), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        emissionToken.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

// ---------------------- MANAGEMENT FUNCTIONS ----------------------

    function setMaxSlippage(uint256 _maxSlippage) external onlyVaultManagers {
        require(_maxSlippage < 10_000);
        maxSlippage = _maxSlippage;
    }

    function stakeAll() external onlyVaultManagers {
        _stakeAll();
    }

    function unstakeAll() external onlyVaultManagers {
        _unstakeAll();
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

// ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    // To add liq, create an array of uints for how much of each asset we want to deposit
    // e.g. for 100 WETH, we would pass [100, 0], native token is always index 0

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantAmount;
        uint256 _minLpToMint = (wantToLpToken(_wantAmount) * (MAX_BIPS - maxSlippage) / MAX_BIPS);
        _checkAllowance(address(lpContract), address(want), _wantAmount);
        /**
         * @param amounts the amounts of each token to add, in their native precision
         * @param minToMint the minimum LP tokens adding this amount of liquidity
         */
        lpContract.addLiquidity(_amountsToAdd, _minLpToMint, block.timestamp);
        _stakeAll();
    }

    function _removeliquidity(uint256 _wantAmount)
        internal
        returns (uint256 _liquidationProfit, uint256 _liquidationLoss)
    {
        _unstakeAll();
        // Math.min to prevent us from withdrawing more than we have
        uint256 _lpAmountToRemove = Math.min(wantToLpToken(_wantAmount), balanceOfUnstakedLPToken());
        uint256 _estimatedTotalAssetsBefore = estimatedTotalAssets();
        uint256 _minWantOut = (_wantAmount * (MAX_BIPS - maxSlippage) / MAX_BIPS) / (10 ** (18 - wantDecimals));

        _checkAllowance(address(lpContract), address(lpToken), _lpAmountToRemove);
        /**
         * @param tokenAmount the amount of the LP token you want to receive
         * @param tokenIndex the index of the token you want to receive
         * @param minAmount the minimum amount to withdraw, otherwise revert
         */
        lpContract.removeLiquidityOneToken(_lpAmountToRemove, 0, _minWantOut, block.timestamp);
        uint256 _estimatedTotalAssetsAfter = estimatedTotalAssets();
        // depending on the reserves balances, there will be a positive or negative price impact
        if (_estimatedTotalAssetsAfter >= _estimatedTotalAssetsBefore) {
            // remove liq resulted in a profit
            return (_estimatedTotalAssetsAfter - _estimatedTotalAssetsBefore, 0);
        } else {
            // remove liq resulted in a loss
            return (0, _estimatedTotalAssetsBefore - _estimatedTotalAssetsAfter);
        }
    }

    function _calculateRemoveLiquidityOneToken(uint256 _lpTokenAmount) public view returns (uint256) {
        return lpContract.calculateRemoveLiquidityOneToken(address(this), _lpTokenAmount, 0);
    }

    // using virtual price (pool_reserves/lp_supply) to estimate LP token value
    function valueLpToWant() public view returns (uint256) {
        uint256 _lpTokenAmount = balanceOfAllLPToken();
        // _lpTokenAmount always has 18 decimals, but sometimes we need to convert back to want with 6 decimals
        uint256 _valueLpToWant = (_lpTokenAmount * lpContract.getVirtualPrice()) / (10 ** (36 - wantDecimals));
        return _valueLpToWant;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    function balanceOfStakedLPToken() public view returns (uint256) {
        return lpStaker.balanceOf(address(this));
    }

    function balanceOfAllLPToken() public view returns (uint256) {
        return balanceOfUnstakedLPToken() + balanceOfStakedLPToken();
    }

    function balanceOfReward() public view returns (uint256) {
        return lpStaker.earned(address(this));
    }

    function wantToLpToken(uint256 _wantAmount) public view returns (uint256 _amount) {
        // lp token always has 18 decimals
        return _wantAmount * 10 ** (36 - wantDecimals) / lpContract.getVirtualPrice();
    }

    function pendingRewards() public view returns (uint256) {
        return lpStaker.earned(address(this));
    }

    function _claimRewards() internal {
        if (pendingRewards() > 0) {
            lpStaker.getReward();
        }
    }

    function _stakeAll() internal returns (uint256) {
        if (balanceOfUnstakedLPToken() > 0) {
            _checkAllowance(address(lpStaker), address(lpStaker.stakingToken()), balanceOfUnstakedLPToken());
            lpStaker.stake(balanceOfUnstakedLPToken());
        }    
    }

    function _unstakeAll() internal returns (uint256) {
        if (balanceOfStakedLPToken() > 0) {
            lpStaker.withdraw(balanceOfStakedLPToken());
        }
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }
}
