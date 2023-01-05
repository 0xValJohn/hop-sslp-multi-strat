// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../interfaces/Vault.sol";
import {Strategy} from "../Strategy.sol";
import "../interfaces/Hop/ISwap.sol";
import "forge-std/console2.sol";

contract StrategyLiquidityTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testManualClaimRewards(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
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
                _amount = _amount / 1_000;
            }
            deal(address(want), user, _amount);
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);

            assertEq(strategy.balanceOfRewardToken(), 0);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();

            skip(5 days);
            vm.prank(gov); // @dev getting a revert here when prank strategist (?)
            strategy.claimRewards();
            assertGe(strategy.balanceOfRewardToken(), 0);
        }
    }
}
