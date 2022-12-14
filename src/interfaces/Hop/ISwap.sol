// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISwap {
    struct SwapStorage {
        uint256 initialA;
        uint256 futureA;
        uint256 initialATime;
        uint256 futureATime;
        uint256 swapFee;
        uint256 adminFee;
        uint256 defaultWithdrawFee;
        address lpToken;
    }

    function getVirtualPrice() external view returns (uint256);

    function calculateTokenAmount(address account, uint256[] calldata amounts, bool deposit)
        external
        view
        returns (uint256);

    function calculateRemoveLiquidity(address account, uint256 amount) external view returns (uint256[] memory);

    function calculateRemoveLiquidityOneToken(address account, uint256 tokenAmount, uint8 tokenIndex)
        external
        view
        returns (uint256 availableTokenAmount);

    function addLiquidity(uint256[] calldata amounts, uint256 minToMint, uint256 deadline) external returns (uint256);

    function removeLiquidityOneToken(uint256 tokenAmount, uint8 tokenIndex, uint256 minAmount, uint256 deadline)
        external
        returns (uint256);

    function removeLiquidityImbalance(uint256[] calldata amounts, uint256 maxBurnAmount, uint256 deadline)
        external
        returns (uint256);

    function swap(uint8 tokenIndexFrom, uint8 tokenIndexTo, uint256 dx, uint256 minDy, uint256 deadline)
        external
        returns (uint256);

    function swapStorage() external view returns (SwapStorage memory);
}
