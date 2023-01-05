// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/Hop/ISwap.sol";
import "./interfaces/Hop/IStakingRewards.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";
import "forge-std/console2.sol"; // @debug for test logging only - to be removed

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event Cloned(address indexed clone);

    bool internal isOriginal = true;
    uint256 private constant max = type(uint256).max;
    address public tradeFactory;
    uint256 public maxSlippage;
    uint256 public maxSingleDeposit;
    IERC20 public lpToken;
    IERC20 public rewardToken;

    ISwap public lpContract;
    IStakingRewards public lpStaker;

    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals;

    constructor(address _vault, uint256 _maxSlippage, uint256 _maxSingleDeposit, address _lpContract, address _lpStaker)
        public
        BaseStrategy(_vault)
    {
        _initializeStrategy(_maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker);
    }

    function _initializeStrategy(uint256 _maxSlippage, uint256 _maxSingleDeposit, address _lpContract, address _lpStaker) internal {
        wantDecimals = IERC20Metadata(address(want)).decimals();
        maxSlippage = _maxSlippage;
        maxSingleDeposit = _maxSingleDeposit * (10 ** wantDecimals);
        lpContract = ISwap(_lpContract);
        lpStaker = IStakingRewards(_lpStaker);
        lpToken = IERC20(lpContract.swapStorage().lpToken);
        rewardToken = IERC20(lpStaker.rewardsToken());
        IERC20(want).safeApprove(address(lpContract), max);
        IERC20(lpToken).safeApprove(address(lpContract), max);
        IERC20(lpToken).safeApprove(address(lpStaker), max);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        uint256 _maxSingleDeposit,
        address _lpContract,
        address _lpStaker
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        uint256 _maxSingleDeposit,
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
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker);

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyHop", IERC20Metadata(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 _balanceOfAllLPToken = balanceOfAllLPToken();
        if (_balanceOfAllLPToken > 0) {
            return balanceOfWant() + lpToWant(_balanceOfAllLPToken);
        } else {
            return balanceOfWant();
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimRewards();
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        unchecked {
            _profit = _totalAssets > _totalDebt ? _totalAssets - _totalDebt : 0;
        }

        // @note free up _debtOutstanding + our profit
        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_toLiquidate > _wantBalance) {
            (_amountFreed, _loss) = withdrawSome(_toLiquidate - _wantBalance);
            _totalAssets = estimatedTotalAssets();
        } else {
            _amountFreed = balanceOfWant();
        }

        uint256 _liquidWant = balanceOfWant();

        // @note calculate final p&l and _debtPayment
        // @note enough to pay profit (partial or full) only
        if (_liquidWant <= _profit) {
            _profit = _liquidWant;
            _debtPayment = 0;
            // @note enough to pay for all profit and _debtOutstanding (partial or full)
        } else {
            _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
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
        uint256 _wantBalance = balanceOfWant();
        if (_wantBalance > _debtOutstanding) {
            uint256 _amountToInvest = Math.min(maxSingleDeposit, _wantBalance - _debtOutstanding);
            _addLiquidity(_amountToInvest);
        }
    }

    function withdrawSome(uint256 _amountNeeded) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _preWithdrawWant = balanceOfWant();
        if (_amountNeeded > 0) {
            uint256 lpAmountNeeded = wantToLp(_amountNeeded);
            _removeliquidity(lpAmountNeeded);
        }

        uint256 _wantFreed = balanceOfWant() - _preWithdrawWant;
        if (_amountNeeded > _wantFreed) {
            _liquidatedAmount = _wantFreed;
            _loss = _amountNeeded - _wantFreed;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBalance = balanceOfWant();

        if (_wantBalance < _amountNeeded) {
            (_liquidatedAmount, _loss) = withdrawSome(_amountNeeded - _wantBalance);
            _wantBalance = balanceOfWant();
        }

        _liquidatedAmount = Math.min(_amountNeeded, _wantBalance);
        require(_amountNeeded >= _liquidatedAmount + _loss, "!check");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _balanceOfAllLPToken = balanceOfAllLPToken();

        if (_balanceOfAllLPToken > 0) {
            _removeliquidity(_balanceOfAllLPToken);
        }

        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _balanceOfStakedLPToken = balanceOfStakedLPToken();
        uint256 _balanceOfRewardToken = balanceOfRewardToken();

        if (_balanceOfStakedLPToken > 0) {
            _unstake(_balanceOfStakedLPToken);
        }

        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();

        if (_balanceOfUnstakedLPToken > 0) {
            lpToken.safeTransfer(_newStrategy, _balanceOfUnstakedLPToken);
        }

        if (_balanceOfRewardToken > 0) {
            rewardToken.safeTransfer(_newStrategy, _balanceOfRewardToken);
        }
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));
        return super.harvestTrigger(callCostInWei) || block.timestamp - params.lastReport > minReportDelay;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    function setMaxSlippage(uint256 _maxSlippage) external onlyVaultManagers {
        require(_maxSlippage < 10_000);
        maxSlippage = _maxSlippage;
    }

    function setmaxSingleDeposit(uint256 _maxSingleDeposit) external onlyVaultManagers {
        maxSingleDeposit = _maxSingleDeposit * (10 ** wantDecimals);
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
        lpContract.addLiquidity(_amountsToAdd, _minLpToMint, max);
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_balanceOfUnstakedLPToken > 0) {
            _stake(_balanceOfUnstakedLPToken);
        }
    }

    function _removeliquidity(uint256 _lpAmount) internal {
        // @note unstake all LP tokens, remove liquidity then restake remaining
        _unstake(balanceOfStakedLPToken());
        _lpAmount = Math.min(balanceOfUnstakedLPToken(), _lpAmount); // @note can't remove more than we have
        uint256 _minWantOut = (_lpAmount * (MAX_BIPS - maxSlippage) / MAX_BIPS) / (10 ** (18 - wantDecimals));
        lpContract.removeLiquidityOneToken(_lpAmount, 0, _minWantOut, max);
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_balanceOfUnstakedLPToken > 0) {
            _stake(_balanceOfUnstakedLPToken);
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

    function balanceOfRewardToken() public view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    function wantToLp(uint256 _wantAmount) public view returns (uint256) {
        // @note decimals: _wantAmount (6 or 18), getVirtualPrice (18), return Lp amount (18))
        return (_wantAmount * 10 ** (36 - wantDecimals)) / lpContract.getVirtualPrice();
    }

    function lpToWant(uint256 _lpAmount) public view returns (uint256) {
        // @note decimals: _lpAmount (18), getVirtualPrice (18), return want amount (6 or 18)
        return (_lpAmount * lpContract.getVirtualPrice()) / (10 ** (36 - wantDecimals));
    }

    function _claimRewards() internal {
        lpStaker.getReward();
    }

    function _stake(uint256 _amountToStake) internal {
        lpStaker.stake(_amountToStake);
    }

    function _unstake(uint256 _amountToUnstake) internal {
        lpStaker.withdraw(_amountToUnstake);
    }
}
