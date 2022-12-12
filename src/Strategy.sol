// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/Hop/ISwap.sol";
import "./interfaces/Hop/IStakingRewards.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";
import "forge-std/console2.sol"; // @debug for test logging only

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

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
        emissionToken = IERC20(lpStaker.rewardsToken());
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

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

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyHop", IERC20Metadata(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + lpToWant(balanceOfAllLPToken());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimRewards();
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        // @note calculate intial profits - no underflow risk
        unchecked { _profit = _totalAssets > _totalDebt ? _totalAssets - _totalDebt : 0; }

        // @note free up _debtOutstanding + our profit
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        // @note  liquidate some of the want
        if (_wantBalance  < _toLiquidate) {
            // @note  liquidation can result in a profit depending on pool balance (slippage)
            (uint256 _liquidationProfit, uint256 _liquidationLoss) = _removeliquidity(_toLiquidate);
            // @note  update the P&L to account for liquidation
            _loss = _loss + _liquidationLoss;
            _profit = _profit + _liquidationProfit;
            _wantBalance  = balanceOfWant();
        }

        // @note calculate final p&L - no underflow risk
        unchecked { (_loss = _loss + (_totalDebt > _totalAssets ? _totalDebt - _totalAssets : 0)); }

        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }

        // @note calculate _debtPayment
        // @note enough to pay for all profit and _debtOutstanding (partial or full)
        if (_wantBalance > _profit) {
	        _debtPayment = Math.min(_wantBalance - _profit, _debtOutstanding);
        // @note enough to pay profit (partial or full) only
        } else {
            _profit = _wantBalance;
            _debtPayment = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantBalance = balanceOfWant();
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
            return (_liquidateAmount, _loss);
        } else {
            return (_amountNeeded, 0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {       
        _unstake(balanceOfStakedLPToken());
        if (balanceOfUnstakedLPToken() > 0) {

            _removeliquidity(balanceOfUnstakedLPToken());
        }
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstake(balanceOfAllLPToken());
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
        emissionToken.safeTransfer(_newStrategy, balanceOfEmissionToken());
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protectedTokens = new address[](1);
        protectedTokens[0] = address(lpToken);
        return protectedTokens;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

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

    function setMaxSlippage(uint256 _maxSlippage) external onlyVaultManagers {
        require(_maxSlippage < 10_000);
        maxSlippage = _maxSlippage;
    }

    function stake(uint256 _amountToStake) external onlyVaultManagers {
        _stake(_amountToStake);
    }

    function unstake(uint256 _amountToUnstake) external onlyVaultManagers {
        _unstake(_amountToUnstake);
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

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantAmount; // @note native token is always index 0
        uint256 _minLpToMint = (wantToLp(_wantAmount) * (MAX_BIPS - maxSlippage) / MAX_BIPS);
        _checkAllowance(address(lpContract), address(want), _wantAmount);
        lpContract.addLiquidity(_amountsToAdd, _minLpToMint, max);
        _stake(balanceOfUnstakedLPToken());
    }

    function _removeliquidity(uint256 _wantAmount)
        internal
        returns (uint256 _liquidationProfit, uint256 _liquidationLoss)
    {
        uint256 _availableLiquidity = availableLiquidity();
        uint256 _lpAmount = wantToLp(_wantAmount);
        uint256 _lpAmountToRemove = Math.min(_availableLiquidity, _lpAmount);
        uint256 _minWantOut = (_lpAmountToRemove * (MAX_BIPS - maxSlippage) / MAX_BIPS) / (10 ** (18 - wantDecimals));
        uint256 _wantBefore = balanceOfWant();
        _unstake(_lpAmountToRemove);
        _checkAllowance(address(lpContract), address(lpToken), _lpAmountToRemove);
        lpContract.removeLiquidityOneToken(_lpAmountToRemove, 0, _minWantOut, max);
        uint256 _wantFreed = balanceOfWant() - _wantBefore;
        
        if (_wantFreed >= _wantAmount) { // @note we realised a profit from positive slippage
            return (_wantFreed - _lpAmountToRemove, 0);
        }
        
        if (_wantAmount > _lpAmountToRemove) { // @note not enought liquidity for full withdraw
            return (0, _availableLiquidity - _wantFreed);

        } else { // @note liquidity was sufficient, but we realised a loss from slippage
            return (0, _wantFreed - _wantAmount);
        }
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

    function claimableRewards() public view returns (uint256) {
        return lpStaker.earned(address(this));
    }

    function availableLiquidity() public view returns (uint256) { // @note returns amount of native asset
        return want.balanceOf(address(lpContract));
    }

    function wantToLp(uint256 _wantAmount) public view returns (uint256) {
        return _wantAmount * 10 ** (36 - wantDecimals) / lpContract.getVirtualPrice();
    }

    function lpToWant(uint256 _lpAmount) public view returns (uint256) {
        return lpContract.getVirtualPrice()/ (10 ** (36 - wantDecimals));
    }

    function _calculateRemoveLiquidityOneToken(uint256 _lpTokenAmount) internal returns (uint256) {
        return lpContract.calculateRemoveLiquidityOneToken(address(this), _lpTokenAmount, 0);
    }

    function _claimRewards() internal {
        lpStaker.getReward();
    }

    function _stake(uint256 _amountToStake) internal {
        _checkAllowance(address(lpStaker), address(lpToken), _amountToStake);
        lpStaker.stake(_amountToStake);
    }

    function _unstake(uint256 _amountToUnstake) internal {
        lpStaker.withdraw(_amountToUnstake);
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }
}
