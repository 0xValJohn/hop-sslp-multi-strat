// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISwap {
    function getVirtualPrice()
        external
        view
        returns (uint256);

    function calculateTokenAmount(address account, uint256[] calldata amounts, bool deposit)
        external
        view 
        returns (uint256);

    function calculateRemoveLiquidity(address account, uint256 amount)
        external
        view
        returns (uint256[] memory);

    function calculateRemoveLiquidityOneToken(address account, uint256 tokenAmount, uint8 tokenIndex)
        external
        view   
        returns (uint256 availableTokenAmount);

    function addLiquidity(uint256[] calldata amounts, uint256 minToMint, uint256 deadline) 
        external
        returns (uint256);

    function removeLiquidityOneToken(uint256 tokenAmount, uint8 tokenIndex, uint256 minAmount, uint256 deadline)
        external
        returns (uint256);
}