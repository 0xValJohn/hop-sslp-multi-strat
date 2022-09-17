// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Vault.sol";
import "../../interfaces/Hop/ISwap.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Strategy} from "../../Strategy.sol";

// Artifact paths for deploying from the deps folder, assumes that the command is run from
// the project root.
string constant vaultArtifact = "artifacts/Vault.json";

// Base fixture deploying Vault
contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    struct AssetFixture { // To test multiple assets
        IVault vault;
        Strategy strategy;
        IERC20 want;
    }

    IERC20 public weth;
    ISwap public hopcontract;

    AssetFixture[] public assetFixtures;

    mapping(string => address) public tokenAddrs;
    mapping(string => uint256) public tokenPrices;
    mapping(string => address) public wantLp;
    mapping(string => address) public hop;
    mapping(string => uint256) public maxSlippage;
    mapping(string => address) public hToken;

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
    // Used for integer approximation
    uint256 public constant DELTA = 1; // being lax here

    function setUp() public virtual {
        _setTokenPrices();
        _setTokenAddrs();
        _setWantLp();
        _setHop();
        _setMaxSlippage();
        _setHToken();

        weth = IERC20(tokenAddrs["WETH"]);

        string[4] memory _tokensToTest = ["WETH","DAI","USDC","USDT"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                address(_want),
                _tokenToTest,
                gov,
                rewards,
                "",
                "",
                guardian,
                management,
                keeper,
                strategist
                );

                assetFixtures.push(AssetFixture(IVault(_vault), Strategy(_strategy), _want));

                vm.label(address(_vault), string(abi.encodePacked(_tokenToTest, "Vault")));
                vm.label(address(_strategy), string(abi.encodePacked(_tokenToTest, "Strategy")));
                vm.label(address(_want), _tokenToTest);
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
        _vault.initialize(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );

        vm.prank(_gov);
        _vault.setDepositLimit(type(uint256).max);

        return address(_vault);
    }

    // Deploys a strategy
    function deployStrategy(
        address _vault,
        string memory _tokenSymbol
        ) public returns (address) {
        Strategy _strategy = new Strategy(
            _vault,
            maxSlippage[_tokenSymbol],
            wantLp[_tokenSymbol],
            hop[_tokenSymbol]
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
        _vaultAddr = deployVault(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );
        IVault _vault = IVault(_vaultAddr);

        vm.prank(_strategist);
        _strategyAddr = deployStrategy(
            _vaultAddr,
            _tokenSymbol);
        Strategy _strategy = Strategy(_strategyAddr);

        vm.prank(_strategist);
        _strategy.setKeeper(_keeper);

        vm.prank(_gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        return (address(_vault), address(_strategy));
    }

    // For Arbitrum ////////////////////////////////////////////////////
    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        tokenAddrs["USDT"] = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        tokenAddrs["USDC"] = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
        tokenAddrs["DAI"] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    }

    function _setWantLp() internal {
        wantLp["WETH"] = 0x59745774Ed5EfF903e615F5A2282Cae03484985a;
        wantLp["USDT"] = 0xCe3B19D820CB8B9ae370E423B0a329c4314335fE;
        wantLp["USDC"] = 0xB67c014FA700E69681a673876eb8BAFAA36BFf71;
        wantLp["DAI"] = 0x68f5d998F00bB2460511021741D098c05721d8fF;
    }

    function _setHop() internal {
        hop["WETH"] = 0x652d27c0F72771Ce5C76fd400edD61B406Ac6D97;
        hop["USDT"] = 0x18f7402B673Ba6Fb5EA4B95768aABb8aaD7ef18a;
        hop["USDC"] = 0x10541b07d8Ad2647Dc6cD67abd4c03575dade261;
        hop["DAI"] = 0xa5A33aB9063395A90CCbEa2D86a62EcCf27B5742;
    }

    function _setHToken() internal {
        hToken["WETH"] = 0xDa7c0de432a9346bB6e96aC74e3B61A36d8a77eB;
        hToken["USDT"] = 0x12e59C59D282D2C00f3166915BED6DC2F5e2B5C7;
        hToken["USDC"] = 0x0ce6c85cF43553DE10FC56cecA0aef6Ff0DD444d;
        hToken["DAI"] = 0x46ae9BaB8CEA96610807a275EBD36f8e916b5C61;
    }    
    ///////////////////////////////////////////////////////////////////

    // For Optimism ///////////////////////////////////////////////////
    // function _setTokenAddrs() internal {
    //     tokenAddrs["WETH"] = 0x4200000000000000000000000000000000000006;
    //     tokenAddrs["USDT"] = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    //     tokenAddrs["USDC"] = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    //     tokenAddrs["DAI"] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    // }

    // function _setWantLp() internal {
    //     wantLp["WETH"] = 0x5C2048094bAaDe483D0b1DA85c3Da6200A88a849;
    //     wantLp["USDT"] = 0xF753A50fc755c6622BBCAa0f59F0522f264F006e;
    //     wantLp["USDC"] = 0x2e17b8193566345a2Dd467183526dEdc42d2d5A8;
    //     wantLp["DAI"] = 0x22D63A26c730d49e5Eab461E4f5De1D8BdF89C92;
    // }

    // function _setHop() internal {
    //     hop["WETH"] = 0xaa30D6bba6285d0585722e2440Ff89E23EF68864;
    //     hop["USDT"] = 0xeC4B41Af04cF917b54AEb6Df58c0f8D78895b5Ef;
    //     hop["USDC"] = 0x3c0FFAca566fCcfD9Cc95139FEF6CBA143795963;
    //     hop["DAI"] = 0xF181eD90D6CfaC84B8073FdEA6D34Aa744B41810;
    // }

    // function _setHToken() internal {
    //     hToken["WETH"] = 0xE38faf9040c7F09958c638bBDB977083722c5156;
    //     hToken["USDT"] = 0x2057C8ECB70Afd7Bee667d76B4CD373A325b1a20;
    //     hToken["USDC"] = 0x25D8039bB044dC227f741a9e381CA4cEAE2E6aE8;
    //     hToken["DAI"] = 0x56900d66D74Cb14E3c86895789901C9135c95b16;
    // }    

    ///////////////////////////////////////////////////////////////////

    function _setMaxSlippage() internal {
        maxSlippage["WETH"] = 100;
        maxSlippage["USDT"] = 100;
        maxSlippage["USDC"] = 100;
        maxSlippage["DAI"] = 100;
    }

    function _setTokenPrices() internal {
        tokenPrices["WETH"] = 1_500;
        tokenPrices["USDT"] = 1;
        tokenPrices["USDC"] = 1;
        tokenPrices["DAI"] = 1;
    }

    // simulating balanced pool (1:1)
    function simulateBalancedPool(string memory _tokenSymbol) public {
        hopcontract = ISwap(address(hop[_tokenSymbol]));
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopcontract));
        uint256 _hTokenInitialBalance = _hToken.balanceOf(address(hopcontract));

        if (_wantInitialBalance > _hTokenInitialBalance) {
            uint256 _hTokenToLP = _wantInitialBalance - _hTokenInitialBalance;
            deal(address(_hToken), whale, _hTokenToLP);
            vm.startPrank(whale);
            _hToken.approve(address(hopcontract), _hTokenToLP);
            uint256[] memory _amountsToAdd = new uint256[](2); 
            _amountsToAdd[1] = _hTokenToLP; 
            hopcontract.addLiquidity(_amountsToAdd, 0, block.timestamp);
            vm.stopPrank();
            }
        else {
            uint256 _wantTokenToLP = _hTokenInitialBalance - _wantInitialBalance;
            deal(address(_want), whale, _wantTokenToLP);
            vm.startPrank(whale);
            _want.approve(address(hopcontract), _wantTokenToLP);
            uint256[] memory _amountsToAdd = new uint256[](2); 
            _amountsToAdd[0] = _wantTokenToLP;
            hopcontract.addLiquidity(_amountsToAdd, 0, block.timestamp);
            vm.stopPrank();
            }
    }

    // simulating want token deposit
    function simulateWantDeposit(string memory _tokenSymbol) public {
        hopcontract = ISwap(address(hop[_tokenSymbol]));
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopcontract));
        uint256 _wantTokenToLP = _wantInitialBalance * 1/2; // add want token in the pool
        deal(address(_want), whale, _wantTokenToLP);
        vm.startPrank(whale);
        _want.approve(address(hopcontract), _wantTokenToLP);
        uint256[] memory _amountsToAdd = new uint256[](2); 
        _amountsToAdd[0] = _wantTokenToLP;
        hopcontract.addLiquidity(_amountsToAdd, 0, block.timestamp);
        vm.stopPrank();
    }

    // simulating LP fees (volume = pool 10x)
    function simulateTransactionFee(string memory _tokenSymbol) public {
        IERC20 _hToken = IERC20(address(hToken[_tokenSymbol]));
        IERC20 _want = IERC20(address(tokenAddrs[_tokenSymbol]));
        hopcontract = ISwap(address(hop[_tokenSymbol]));
        uint256 _wantInitialBalance = _want.balanceOf(address(hopcontract));
        uint256 _hTokenInitialBalance = _hToken.balanceOf(address(hopcontract));
        for (uint i = 0; i < 10; i++) { // generate fees for volume equal to total pool * 2 (back and forth) * x
            vm.startPrank(whale);
            deal(address(_want), whale, _hTokenInitialBalance);
            _want.approve(address(hopcontract), _hTokenInitialBalance);
            hopcontract.swap(0, 1, _hTokenInitialBalance, 0, block.timestamp); // swap hToken to want
            deal(address(_hToken), whale, _wantInitialBalance);
            _hToken.approve(address(hopcontract), _wantInitialBalance);
            hopcontract.swap(1, 0, _wantInitialBalance, 0, block.timestamp); // swap want back to hToken
            vm.stopPrank();
        }
        simulateBalancedPool(_tokenSymbol); // get the pool back in line
    }

}
