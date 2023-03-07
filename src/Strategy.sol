// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/Hop/ISwap.sol";
import "./interfaces/Hop/IStakingRewards.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";

struct route {
    address from;
    address to;
    bool stable;
}

interface IVelodromeRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

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

    address internal constant velodromeRouter = 0xa132DAB612dB5cB9fC9Ac426A0Cc215A3423F9c9;

    struct route {
        address from;
        address to;
        bool stable;
    }

    route[] public routes;

    constructor(address _vault, uint256 _maxSlippage, uint256 _maxSingleDeposit, address _lpContract, address _lpStaker, string memory _sellRewardsRoute)
        public
        BaseStrategy(_vault)
    {
        _initializeStrategy(_maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker, _sellRewardsRoute);
    }

    function _initializeStrategy(uint256 _maxSlippage, uint256 _maxSingleDeposit, address _lpContract, address _lpStaker, string memory _sellRewardsRoute) internal {
        minReportDelay = 21 days; // time to trigger harvesting by keeper depending on gas base fee
        maxReportDelay = 100 days; // time to trigger haresting by keeper no matter what
        wantDecimals = IERC20Metadata(address(want)).decimals();
        maxSlippage = _maxSlippage;
        maxSingleDeposit = _maxSingleDeposit;
        healthCheck = 0x3d8F58774611676fd196D26149C71a9142C45296;
        lpContract = ISwap(_lpContract);
        lpStaker = IStakingRewards(_lpStaker);
        lpToken = IERC20(lpContract.swapStorage().lpToken);
        rewardToken = IERC20(lpStaker.rewardsToken());
        require(address(lpContract.getToken(0)) == address(want), "!want");
        IERC20(want).safeApprove(address(lpContract), max);
        IERC20(rewardToken ).safeApprove(address(velodromeRouter), max);
        IERC20(lpToken).safeApprove(address(lpContract), max);
        IERC20(lpToken).safeApprove(address(lpStaker), max);

        // define the hop --> want route for velodrome
        bytes memory _sellRewardsRouteData = bytes(_sellRewardsRoute);
        route[] memory sellRewardsRoute = abi.decode(_sellRewardsRouteData, (route[]));
        for (uint256 i = 0; i < sellRewardsRoute.length; i++) {
            routes.push(sellRewardsRoute[i]);
        }
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        uint256 _maxSingleDeposit,
        address _lpContract,
        address _lpStaker,
        string memory _sellRewardsRoute
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker, _sellRewardsRoute);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        uint256 _maxSingleDeposit,
        address _lpContract,
        address _lpStaker,
        string memory _sellRewardsRoute
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
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _maxSlippage, _maxSingleDeposit, _lpContract, _lpStaker, _sellRewardsRoute);

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

        uint256 _balanceOfRewardToken = balanceOfRewardToken();
        if (_balanceOfRewardToken > 0) {
            _sell(_balanceOfRewardToken);
        }

        _debtPayment = _debtOutstanding;
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _wantBalance = balanceOfWant();

        if (_totalDebt < _totalAssets){
            unchecked { _profit = _totalAssets - _totalDebt; }
        }
        else {
            unchecked { _loss = _totalDebt - _totalAssets; }
        }

        uint256 _toLiquidate = _debtPayment + _profit;

        // @note _loss from withdrawals are recognised here
        if (_toLiquidate > _wantBalance) {
            unchecked { _toLiquidate -= _wantBalance; }
            (, uint256 _withdrawLoss) = withdrawSome(_toLiquidate);

            if(_withdrawLoss < _profit){
                unchecked { _profit -= _withdrawLoss; }
            }
            else {
                unchecked { _loss = _loss + _withdrawLoss - _profit; }
                _profit = 0;
            }

            uint256 _liquidWant = balanceOfWant();
            
            if (_liquidWant <= _profit) {
                _profit = _liquidWant;
                _debtPayment = 0;
            } else if (_liquidWant < _debtPayment + _profit) {
                _debtPayment = _liquidWant - _profit;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantBalance = balanceOfWant();
        if (_wantBalance > _debtOutstanding) {
            uint256 _amountToInvest = Math.min(maxSingleDeposit, _wantBalance - _debtOutstanding);
            _addLiquidity(_amountToInvest);
            uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
            if (_balanceOfUnstakedLPToken > 0) {
                _stake(_balanceOfUnstakedLPToken);
            }
        }
    }

    function withdrawSome(uint256 _amountNeeded) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _preWithdrawWant = balanceOfWant();
        if (_amountNeeded > 0) {
            uint256 lpAmountNeeded = wantToLp(_amountNeeded);
            _removeLiquidity(lpAmountNeeded);
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
            _removeLiquidity(_balanceOfAllLPToken);
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
        return super.harvestTrigger(callCostInWei) && ((block.timestamp - params.lastReport) > minReportDelay);
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    function setMaxSlippage(uint256 _maxSlippage) external onlyVaultManagers {
        require(_maxSlippage < 10_000);
        maxSlippage = _maxSlippage;
    }

    function setMaxSingleDeposit(uint256 _maxSingleDeposit) external onlyVaultManagers {
        maxSingleDeposit = _maxSingleDeposit;
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

    function removeLiquidity(uint256 _wantAmount) external onlyVaultManagers {
        _removeLiquidity(_wantAmount);
    }

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantAmount; // @note native token is always index 0
        uint256 _minLpToMint = (wantToLp(_wantAmount) * (MAX_BIPS - maxSlippage) / MAX_BIPS);
        lpContract.addLiquidity(_amountsToAdd, _minLpToMint, max);
    }

    function _removeLiquidity(uint256 _lpAmount) internal {
        // @note unstake LP token if required
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_lpAmount > _balanceOfUnstakedLPToken) {
            _unstake(Math.min(_lpAmount - _balanceOfUnstakedLPToken, balanceOfStakedLPToken()));
        }

        _lpAmount = Math.min(balanceOfUnstakedLPToken(), _lpAmount); // @note can't remove more than we have
        uint256 _minWantOut = (_lpAmount * (MAX_BIPS - maxSlippage) / MAX_BIPS) / (10 ** (18 - wantDecimals));
        lpContract.removeLiquidityOneToken(_lpAmount, 0, _minWantOut, max);
    }

    // Takes a json string to define the hop --> want route for velodrome
    function setSellRewardsRoute(string memory json) external onlyVaultManagers {
        bytes memory jsonData = bytes(json);
        require(jsonData.length > 0, "Empty input");
        sellRewardsRoute = abi.decode(jsonData, (route[]));
        for (uint256 i = 0; i < sellRewardsRoute.length; i++) {
            routes.push(sellRewardsRoute[i]);
        }
    }

    // Sells HOP for want
    function _sell(uint256 _rewardTokenAmount) internal {      
        if (_rewardTokenAmount > 1e17) {
            IVelodromeRouter(velodromeRouter).swapExactTokensForTokens(
                _rewardTokenAmount, // amountIn
                0, // amountOutMin
                sellRewardsRoute,
                address(this), // to
                block.timestamp // deadline
            );
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
