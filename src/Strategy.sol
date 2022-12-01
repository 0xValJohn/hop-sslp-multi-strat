// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

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

    bool internal isOriginal = true;
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
        address _lpContract,
        address _lpStaker
    ) public BaseStrategy(_vault) {
        _initializeStrategy(
            _maxSlippage,
            _lpContract,
            _lpStaker);
    }

    function _initializeStrategy(
        uint256 _maxSlippage,
        address _lpContract,
        address _lpStaker
    ) internal {
        maxSlippage = _maxSlippage;
        lpContract = ISwap(_lpContract);
        lpStaker = IStakingRewards(_lpStaker);
        lpToken = IERC20(lpContract.swapStorage().lpToken);
        emissionToken = IERC20(lpStaker.stakingToken());
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

// ---------------------- CLONING ----------------------
    event Cloned(address indexed clone);

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        address _lpContract,
        address _lpStaker
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_maxSlippage, _lpContract, _lpStaker);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        address _lpContract,
        address _lpStaker
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }
        Strategy(newStrategy).initialize(
            _vault, _strategist, _rewards, _keeper, _maxSlippage, _lpContract, _lpStaker
        );

        emit Cloned(newStrategy);
    }

// ---------------------- MAIN ----------------------

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyHop", IERC20Metadata(address(want)).symbol()));
    }

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

        // @dev calculate intial profits - no underflow risk
        unchecked { _profit = _totalAssets > _totalDebt ? _totalAssets - _totalDebt : 0; }

        // @dev free up _debtOutstanding + our profit
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        // @dev  liquidate some of the want
        if (_wantBalance  < _toLiquidate) {
            // @dev  liquidation can result in a profit depending on pool balance (slippage)
            (uint256 _liquidationProfit, uint256 _liquidationLoss) = _removeliquidity(_toLiquidate);
            // @dev  update the P&L to account for liquidation
            _loss = _loss + _liquidationLoss;
            _profit = _profit + _liquidationProfit;
            _wantBalance  = balanceOfWant();
        }

        // @dev calculate final p&L - no underflow risk
        unchecked { (_loss = _loss + (_totalDebt > _totalAssets ? _totalDebt - _totalAssets : 0)); }

        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }

        // @dev calculate _debtPayment
        // @dev enough to pay for all profit and _debtOutstanding (partial or full)
        if (_liquidWant > _profit) {
	        _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
        // @dev enough to pay profit (partial or full) only
        } else {
            _profit = _liquidWant;
            _debtPayment = 0;
        }
        forceHarvestTriggerOnce = false; // @dev for vault < 0.4.5, reset our trigger if we used it
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantBalance  = balanceOfWant();
        if (_wantBalance  > _debtOutstanding) {
            uint256 _amountToInvest = _wantBalance  - _debtOutstanding;
            _addLiquidity(_amountToInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBalance  = balanceOfWant();
        if (_wantBalance  < _amountNeeded) {
            (_loss, ) = _removeliquidity(_amountNeeded - _wantBalance);
            _liquidatedAmount = Math.min(balanceOfWant(),_amountNeeded);
        } else {
            return (_amountNeeded, 0);
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
        emissionToken.safeTransfer(_newStrategy, balanceOfEmissionToken());
    }

// ---------------------- KEEP3RS ----------------------

    function harvestTrigger(uint256 callCostinEth) public view override returns (bool) {
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        if (block.timestamp - params.lastReport > maxReportDelay) {
            return true;
        }

        if (!isBaseFeeAcceptable()) {
            return false;
        }

        if (forceHarvestTriggerOnce) {
            return true;
        }

        if (block.timestamp - params.lastReport > minReportDelay) {
            return true;
        }

        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        return false;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

// ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

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

    function addLiquidity(uint256 _wantAmount) external onlyVaultManagers {
        _addLiquidity(_wantAmount);
    }

    function removeliquidity(uint256 _wantAmount) external onlyVaultManagers {
        _removeliquidity(_wantAmount);
    }

// ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantAmount; // @dev native token is always index 0
        uint256 _minLpToMint = (wantToLpToken(_wantAmount) * (MAX_BIPS - maxSlippage) / MAX_BIPS);
        _checkAllowance(address(lpContract), address(want), _wantAmount);
        lpContract.addLiquidity(_amountsToAdd, _minLpToMint, max);
        _stakeAll();
    }

    function _removeliquidity(uint256 _wantAmount)
        internal
        returns (uint256 _liquidationProfit, uint256 _liquidationLoss)
    {
        _unstakeAll();
        uint256 _availableLiquidity = availableLiquidity();
        uint256 _wantToLpToken = wantToLpToken(_wantAmount);
        uint256 _lpAmountToRemove = Math.min(_wantToLpToken, _availableLiquidity); // @dev can't withdraw more than we have / is available
        uint256 _minWantOut = (_wantAmount * (MAX_BIPS - maxSlippage) / MAX_BIPS) / (10 ** (18 - wantDecimals));
        uint256 _wantBefore = balanceOfWant();
        _checkAllowance(address(lpContract), address(lpToken), _lpAmountToRemove);
        lpContract.removeLiquidityOneToken(_lpAmountToRemove, 0, _minWantOut, max);
        uint256 _wantFreed = balanceOfWant() - _wantBefore;
        
        if (_wantFreed >= _wantAmount) { // @dev we realised a profit from positive slippage
            return (_wantFreed - _lpAmountToRemove, 0);
        }
        
        if (_wantAmount > _wantToLpToken) { // @dev not enought liquidity for full withdraw
            return (0, _availableLiquidity - _wantFreed);

        } else { // @dev liquidity was sufficient, but we realised a loss from slippage
            return (0, _wantFreed - _wantAmount);
        }

        _stakeAll();
    }

    // @dev using virtual price (pool_reserves/lp_supply) to estimate LP token value
    function valueLpToWant() public view returns (uint256) {
        uint256 _lpTokenAmount = balanceOfAllLPToken();
        uint256 _valueLpToWant = (_lpTokenAmount * lpContract.getVirtualPrice()) / (10 ** (36 - wantDecimals)); //@dev decimals conversion, _lpTokenAmount always has 18 decimals
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

    function balanceOfEmissionToken() public view returns (uint256) {
        return emissionToken.balanceOf(address(this));
    }

    function wantToLpToken(uint256 _wantAmount) public view returns (uint256 _amount) { // @dev  assumes a balanced pool, for estimate only
        return _wantAmount * 10 ** (36 - wantDecimals) / lpContract.getVirtualPrice(); // @dev lp token always has 18 decimals
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

    function availableLiquidity() public view returns (uint256) { // @dev returns the amount of native asset avail.
        return want.balanceOf(address(lpContract));
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }
}