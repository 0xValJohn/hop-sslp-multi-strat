// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {IVault} from "../interfaces/Vault.sol";
import {Strategy} from "../Strategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StrategyOperationsTest is StrategyFixture {
    // setup is run on before each test
    function setUp() public override {
        // setup vault
        super.setUp();
    }

    /// Test Operations
    function testStrategyOperation(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);
            uint256 balanceBefore = want.balanceOf(address(user));
            
            // simulate a balanced pool
            simulateBalancedPool(_wantSymbol);

            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            skip(60);
            // tend
            vm.prank(strategist);
            strategy.tend();

            // simulate LP fees
            simulateTransactionFee(_wantSymbol);

            vm.startPrank(user);
            vault.withdraw(vault.balanceOf(user), user, 600);
            vm.stopPrank();

            assertRelApproxEq(want.balanceOf(user), balanceBefore, DELTA);

        }
    }

    function testEmergencyExit(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);
            
            // simulate a balanced pool
            simulateBalancedPool(_wantSymbol);

            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // set emergency and exit
            vm.prank(gov);
            strategy.setEmergencyExit();
            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            assertLt(strategy.estimatedTotalAssets(), _amount);
        }
    }

    function testProfitableHarvest(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);
            
            // simulate a balanced pool
            simulateBalancedPool(_wantSymbol);

            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            uint256 _beforePps = vault.pricePerShare();
            
            // 1st harvest
            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // simulate LP fees
            simulateTransactionFee(_wantSymbol);

            // Harvest and check that the vault price increased
            skip(60);
            vm.prank(strategist);
            strategy.harvest();
            skip(60);
            assertGt(vault.pricePerShare(), _beforePps);
        }
    }

    function testChangeDebt(uint256 _fuzzAmount) public {
         vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);

            // Deposit to the vault and harvest
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);
            skip(7 days);
            vm.prank(strategist);
            strategy.harvest();
            uint256 half = uint256(_amount / 2);
            assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);

            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 10_000);
            skip(7 days);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);
        }
    }

    function testSweep(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);

            // Strategy want token doesn't work
            vm.prank(user);
            want.transfer(address(strategy), _amount);
            assertEq(address(want), address(strategy.want()));
            assertGt(want.balanceOf(address(strategy)), 0);

            vm.prank(gov);
            vm.expectRevert("!want");
            strategy.sweep(address(want));

            // Vault share token doesn't work
            vm.prank(gov);
            vm.expectRevert("!shares");
            strategy.sweep(address(vault));

            // TODO: If you add protected tokens to the strategy.
            // Protected token doesn't work
            // vm.prank(gov);
            // vm.expectRevert("!protected");
            // strategy.sweep(strategy.protectedToken());

            // not applicable as we have a strat for weth
            
            // uint256 beforeBalance = weth.balanceOf(gov);
            // uint256 wethAmount = 1 ether;
            // deal(address(weth), user, wethAmount);
            // vm.prank(user);
            // weth.transfer(address(strategy), wethAmount);
            // assertNeq(address(weth), address(strategy.want()));
            // assertEq(weth.balanceOf(user), 0);
            // vm.prank(gov);
            // strategy.sweep(address(weth));
            // assertRelApproxEq(
            //     weth.balanceOf(gov),
            //     wethAmount + beforeBalance,
            //     DELTA
            // );
        }
    }

    function testTriggers(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        // logic for multi-want
        for(uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }

            deal(address(want), user, _amount);

            // Deposit to the vault and harvest
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);
            skip(7 days);
            vm.prank(strategist);
            strategy.harvest();

            strategy.harvestTrigger(0);
            strategy.tendTrigger(0);
        }
    }
}
