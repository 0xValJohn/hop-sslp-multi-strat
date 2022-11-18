// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Strategy} from "../Strategy.sol";
import {IVault} from "../interfaces/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StrategyMigrationTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testStrategyClone(uint256 _amount) public {
         vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);

        // Logic for multi-want testing
        for (uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint8 _wantDecimals = ERC20(address(want)).decimals();
            string memory _wantSymbol = ERC20(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }
        //

            deal(address(want), user, _amount);
            string memory tokenSymbol = ERC20(address(want)).symbol();

            uint256 _balanceBefore = want.balanceOf(address(user));

            vm.prank(user);
            want.approve(address(vault), _amount);

            vm.prank(user);
            vault.deposit(_amount);

            address _newStrategy = strategy.cloneHop(
                address(vault),
                strategist,
                rewards,
                keeper,
                maxSlippage[tokenSymbol],
                lpToken[tokenSymbol],
                emissionToken[tokenSymbol],
                lpContract[tokenSymbol],
                lpStaker[tokenSymbol]
            );

            vm.prank(gov);
            vault.migrateStrategy(address(strategy), _newStrategy);
            strategy = Strategy(_newStrategy);

            // simulate a balanced pool
            simulateBalancedPool(_wantSymbol);

            // simulate LP fees
            simulateTransactionFee(_wantSymbol);

            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // simulate favorable withdraw conditions
            simulateWantDeposit(_wantSymbol);

            vm.prank(strategist);
            skip(60);
            strategy.tend();

            vm.prank(user);
            vault.withdraw();

            assertRelApproxEq(want.balanceOf(user), _balanceBefore, DELTA);
        }
    }

    function testStrategyCloneOfClone(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        
        // Logic for multi-want testing
        for (uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint8 _wantDecimals = ERC20(address(want)).decimals();
            string memory _wantSymbol = ERC20(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }
        //

            deal(address(want), user, _amount);
            string memory tokenSymbol = ERC20(address(want)).symbol();

            address _newStrategy = strategy.cloneHop(
                address(vault),
                strategist,
                rewards,
                keeper,
                maxSlippage[tokenSymbol],
                lpToken[tokenSymbol],
                emissionToken[tokenSymbol],
                lpContract[tokenSymbol],
                lpStaker[tokenSymbol]
            );

            vm.prank(gov);
            vault.migrateStrategy(address(strategy), _newStrategy);

            strategy = Strategy(_newStrategy);

            vm.expectRevert(abi.encodePacked("!clone"));
            strategy.cloneHop(
                address(vault),
                strategist,
                rewards,
                keeper,
                maxSlippage[tokenSymbol],
                lpToken[tokenSymbol],
                emissionToken[tokenSymbol],
                lpContract[tokenSymbol],
                lpStaker[tokenSymbol]
            );
        }
    }

    function testStrategyDoubleInitialize(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        
        // Logic for multi-want testing
        for (uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint8 _wantDecimals = ERC20(address(want)).decimals();
            string memory _wantSymbol = ERC20(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }
        //

            deal(address(want), user, _amount);

            string memory tokenSymbol = ERC20(address(want)).symbol();

            address _newStrategy = strategy.cloneHop(
                address(vault),
                strategist,
                rewards,
                keeper,
                maxSlippage[tokenSymbol],
                lpToken[tokenSymbol],
                emissionToken[tokenSymbol],
                lpContract[tokenSymbol],
                lpStaker[tokenSymbol]
            );

            vm.prank(gov);
            vault.migrateStrategy(address(strategy), _newStrategy);

            strategy = Strategy(_newStrategy);

            vm.expectRevert(abi.encodePacked("Strategy already initialized"));
            strategy.initialize(
                address(vault),
                strategist,
                rewards,
                keeper,
                maxSlippage[tokenSymbol],
                lpToken[tokenSymbol],
                emissionToken[tokenSymbol],
                lpContract[tokenSymbol],
                lpStaker[tokenSymbol]
            );
        }
    }
}