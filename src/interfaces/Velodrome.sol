// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}