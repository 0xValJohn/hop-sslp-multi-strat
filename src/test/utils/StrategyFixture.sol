// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Vault.sol";
import {Strategy} from "../../Strategy.sol";
import "../../interfaces/Hop/ISwap.sol";
import "forge-std/console2.sol";

interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }
}

string constant vaultArtifact = "artifacts/Vault.json";

contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    struct AssetFixture {
        IVault vault;
        Strategy strategy;
        IERC20 want;
    }

    IERC20 public weth;
    ISwap public hopContract;

    AssetFixture[] public assetFixtures;

    mapping(string => uint256) public maxSlippage;
    mapping(string => uint256) public maxSingleDeposit;
    mapping(string => address) public lpStaker;
    mapping(string => address) public lpContract;
    mapping(string => address) public tokenAddrs;
    mapping(string => uint256) public tokenPrices;
    mapping(string => address) public hToken;
    mapping(string => IVelodromeRouter.Route[]) public veloRoute;

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public user = address(1);
    address public whale = address(2);
    address public rewards = address(3);
    address public guardian = address(4);
    address public management = address(5);
    address public strategist = address(6);
    address public keeper = address(7);

    uint256 public minFuzzAmt = 1_000 ether;
    // @dev maximum amount of want tokens deposited based on @maxDollarNotional
    uint256 public maxFuzzAmt = 1_000_000 ether; // keeping in mind the WETH mod --> 100 WETH --> 0.1 WETH
    // @dev maximum dollar amount of tokens to be deposited
    uint256 public constant DELTA = 10 ** 1;

    function setUp() public virtual {
        _setTokenPrices();
        _setTokenAddrs();
        _setMaxSlippage();
        _setMaxSingleDeposit();
        _setLpContract();
        _setLpStaker();
        _setHToken();
        _setVeloRoute();

        weth = IERC20(tokenAddrs["WETH"]);

        // want selector for strategy
        // string[4] memory _tokensToTest = ["DAI", "USDT", "USDC", "WETH"];
        string[1] memory _tokensToTest = ["USDC"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                address(_want), _tokenToTest, gov, rewards, "", "", guardian, management, keeper, strategist
            );

            assetFixtures.push(AssetFixture(IVault(_vault), Strategy(_strategy), _want));

            vm.label(address(_vault), string(abi.encodePacked(_tokenToTest, "Vault")));
            vm.label(address(_strategy), string(abi.encodePacked(_tokenToTest, "Strategy")));
            vm.label(address(_want), _tokenToTest);

            // poolBalancesHelper(_tokenToTest);
        }

        // add more labels to make your traces readable
        vm.label(gov, "Gov");
        vm.label(user, "User");
        vm.label(whale, "Whale");
        vm.label(rewards, "Rewards");
        vm.label(guardian, "Guardian");
        vm.label(management, "Management");
        vm.label(strategist, "Strategist");
        vm.label(keeper, "Keeper");
    }

    // Deploys a vault
    function deployVault(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management
    ) public returns (address) {
        vm.prank(_gov);
        address _vaultAddress = deployCode(vaultArtifact);
        IVault _vault = IVault(_vaultAddress);

        vm.prank(_gov);
        _vault.initialize(_token, _gov, _rewards, _name, _symbol, _guardian, _management);

        vm.prank(_gov);
        _vault.setDepositLimit(type(uint256).max);

        return address(_vault);
    }

    // Deploys a strategy
    function deployStrategy(address _vault, string memory _tokenSymbol) public returns (address) {

        // uint length = veloRoute[_tokenSymbol].length;

        // IVelodromeRouter.Route[] memory memoryRoutes = new IVelodromeRouter.Route[](length);

        // for (uint i = 0; i < length; i++) {
        //     memoryRoutes[i].from = veloRoute[_tokenSymbol][i].from;
        //     memoryRoutes[i].to = veloRoute[_tokenSymbol][i].to;
        //     memoryRoutes[i].stable = veloRoute[_tokenSymbol][i].stable;
        //     console2.log(memoryRoutes[i].from);
        // }
        
        // IVelodromeRouter.Route[] memory route = new IVelodromeRouter.Route[](1);
        // route[0].from = HOP;
        // route[0].to = tokenAddrs["WETH"];
        // route[0].stable = false;
        // veloRoute["WETH"] = route; // Set route
        
        Strategy _strategy = new Strategy(
            _vault,
            maxSlippage[_tokenSymbol],
            maxSingleDeposit[_tokenSymbol],
            lpContract[_tokenSymbol],
            lpStaker[_tokenSymbol]
        );

        return address(_strategy);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(
        address _token,
        string memory _tokenSymbol,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management,
        address _keeper,
        address _strategist
    ) public returns (address _vaultAddr, address _strategyAddr) {
        _vaultAddr = deployVault(_token, _gov, _rewards, _name, _symbol, _guardian, _management);
        IVault _vault = IVault(_vaultAddr);

        vm.prank(_strategist);
        _strategyAddr = deployStrategy(_vaultAddr, _tokenSymbol);
        Strategy _strategy = Strategy(_strategyAddr);

        uint length = veloRoute[_tokenSymbol].length;
        IVelodromeRouter.Route[] memory memoryRoutes = new IVelodromeRouter.Route[](length);

        for (uint i = 0; i < length; i++) {
            memoryRoutes[i] = veloRoute[_tokenSymbol][i];
        }

        _strategy.setSellRewardsRoute(memoryRoutes);

        vm.prank(_strategist);
        _strategy.setKeeper(_keeper);

        vm.prank(_gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        return (address(_vault), address(_strategy));
    }

    // For Optimism ///////////////////////////////////////////////////
    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0x4200000000000000000000000000000000000006;
        tokenAddrs["USDT"] = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
        tokenAddrs["USDC"] = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
        tokenAddrs["DAI"] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    }

    function _setLpContract() internal {
        lpContract["WETH"] = 0xaa30D6bba6285d0585722e2440Ff89E23EF68864;
        lpContract["USDT"] = 0xeC4B41Af04cF917b54AEb6Df58c0f8D78895b5Ef;
        lpContract["USDC"] = 0x3c0FFAca566fCcfD9Cc95139FEF6CBA143795963;
        lpContract["DAI"] = 0xF181eD90D6CfaC84B8073FdEA6D34Aa744B41810;
    }

    function _setLpStaker() internal {
        lpStaker["WETH"] = 0x95d6A95BECfd98a7032Ed0c7d950ff6e0Fa8d697;
        lpStaker["USDT"] = 0xAeB1b49921E0D2D96FcDBe0D486190B2907B3e0B;
        lpStaker["USDC"] = 0xf587B9309c603feEdf0445aF4D3B21300989e93a;
        lpStaker["DAI"] = 0x392B9780cFD362bD6951edFA9eBc31e68748b190;
    }

    function _setHToken() internal {
        hToken["WETH"] = 0xE38faf9040c7F09958c638bBDB977083722c5156;
        hToken["USDT"] = 0x2057C8ECB70Afd7Bee667d76B4CD373A325b1a20;
        hToken["USDC"] = 0x25D8039bB044dC227f741a9e381CA4cEAE2E6aE8;
        hToken["DAI"] = 0x56900d66D74Cb14E3c86895789901C9135c95b16;
    }

    // set optimal route for selling HOP --> want on Velodrome
    // (address,address,bool)[]
    function _setVeloRoute() internal {
        address HOP = 0xc5102fE9359FD9a28f877a67E36B0F050d81a3CC;

        // WETH
        IVelodromeRouter.Route memory route = IVelodromeRouter.Route({
            from: HOP, 
            to: tokenAddrs["WETH"], 
            stable: false
        });
        // All tokens have this common route
        veloRoute["WETH"].push(route);
        veloRoute["USDT"].push(route);
        veloRoute["USDC"].push(route);
        veloRoute["DAI"].push(route);

        // // USDT
        route = IVelodromeRouter.Route({
            from: tokenAddrs["WETH"], 
            to: tokenAddrs["USDT"], 
            stable: false
        });
        veloRoute["USDT"].push(route);

        // // USDC
        route = IVelodromeRouter.Route({
            from: tokenAddrs["WETH"], 
            to: tokenAddrs["USDC"], 
            stable: false
        });
        veloRoute["USDC"].push(route);

        // // DAI
        route = IVelodromeRouter.Route({
            from: tokenAddrs["WETH"], 
            to: tokenAddrs["DAI"], 
            stable: false
        });
        veloRoute["DAI"].push(route);
    }
    /////////////////////////////////////////////////////////////////

    function _setMaxSlippage() internal {
        maxSlippage["WETH"] = 100;
        maxSlippage["USDT"] = 100;
        maxSlippage["USDC"] = 100;
        maxSlippage["DAI"] = 100;
    }

    function _setMaxSingleDeposit() internal {
        maxSingleDeposit["WETH"] = 5_000_000;
        maxSingleDeposit["USDT"] = 50_000_000;
        maxSingleDeposit["USDC"] = 50_000_000;
        maxSingleDeposit["DAI"] = 50_000_000;
    }

    function _setTokenPrices() internal {
        tokenPrices["WETH"] = 1_500;
        tokenPrices["USDT"] = 1;
        tokenPrices["USDC"] = 1;
        tokenPrices["DAI"] = 1;
    }

    // simulating balanced pool (1:1)
    function simulateBalancedPool(string memory _tokenSymbol) public {
        hopContract = ISwap(address(lpContract[_tokenSymbol]));
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopContract));
        uint256 _hTokenInitialBalance = _hToken.balanceOf(address(hopContract));

        if (_wantInitialBalance > _hTokenInitialBalance) {
            uint256 _hTokenToLP = _wantInitialBalance - _hTokenInitialBalance;
            deal(address(_hToken), whale, _hTokenToLP);
            vm.startPrank(whale);
            _hToken.approve(address(hopContract), _hTokenToLP);
            uint256[] memory _amountsToAdd = new uint256[](2);
            _amountsToAdd[1] = _hTokenToLP;
            hopContract.addLiquidity(_amountsToAdd, 0, block.timestamp);
            vm.stopPrank();
        } else {
            uint256 _wantTokenToLP = _hTokenInitialBalance - _wantInitialBalance;
            deal(address(_want), whale, _wantTokenToLP);
            vm.startPrank(whale);
            _want.approve(address(hopContract), _wantTokenToLP);
            uint256[] memory _amountsToAdd = new uint256[](2);
            _amountsToAdd[0] = _wantTokenToLP;
            hopContract.addLiquidity(_amountsToAdd, 0, block.timestamp);
            vm.stopPrank();
        }
    }

    // simulating want token deposit
    function simulateWantDeposit(string memory _tokenSymbol) public {
        hopContract = ISwap(address(lpContract[_tokenSymbol]));
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopContract));
        uint256 _wantTokenToLP = _wantInitialBalance * 1 / 2; // add want token in the pool
        deal(address(_want), whale, _wantTokenToLP);
        vm.startPrank(whale);
        _want.approve(address(hopContract), _wantTokenToLP);
        uint256[] memory _amountsToAdd = new uint256[](2);
        _amountsToAdd[0] = _wantTokenToLP;
        hopContract.addLiquidity(_amountsToAdd, 0, block.timestamp);
        vm.stopPrank();
    }

    // simulating LP fees (volume = pool 10x)
    function simulateTransactionFee(string memory _tokenSymbol) public {
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        ISwap hopContract = ISwap(address(lpContract[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopContract));
        uint256 _hTokenInitialBalance = _hToken.balanceOf(address(hopContract));
        for (uint256 i = 0; i < 10; i++) {
            // generate fees for volume equal to total pool * 2 (back and forth) * x
            vm.startPrank(whale);
            deal(address(_want), whale, _hTokenInitialBalance);
            _want.approve(address(hopContract), _hTokenInitialBalance);
            hopContract.swap(0, 1, _hTokenInitialBalance, 0, block.timestamp); // swap hToken to want
            deal(address(_hToken), whale, _wantInitialBalance);
            _hToken.approve(address(hopContract), _wantInitialBalance);
            hopContract.swap(1, 0, _wantInitialBalance, 0, block.timestamp); // swap want back to hToken
            vm.stopPrank();
        }
        simulateBalancedPool(_tokenSymbol); // get the pool back in line
        console2.log("_want.balanceOf(address(hopContract)", _want.balanceOf(address(hopContract)));
        console2.log("_hToken.balanceOf(address(hopContract))", _hToken.balanceOf(address(hopContract)));
    }

    function poolBalancesHelper(string memory _tokenSymbol) public view {
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        ISwap hopContract = ISwap(address(lpContract[_tokenSymbol]));
        console2.log(
            "{poolBalancesHelper} _want / _hToken",
            _tokenSymbol,
            _want.balanceOf(address(hopContract)) / (10 ** ERC20(address(_want)).decimals()),
            _hToken.balanceOf(address(hopContract)) / (10 ** ERC20(address(_hToken)).decimals())
        );
    }
}
