// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

interface IPancakeMasterChefV3 {
    function CAKE() external view returns (address);
    function nonfungiblePositionManager() external view returns (address);
    function v3PoolAddressPid(address v3Pool) external view returns (uint256 pid);

    function poolInfo(uint256 pid)
        external
        view
        returns (
            uint256 allocPoint,
            IUniswapV3Pool v3Pool,
            address token0,
            address token1,
            uint24 fee,
            uint256 totalLiquidity,
            uint256 totalBoostLiquidity
        );

    function pendingCake(uint256 tokenId) external view returns (uint256 reward);
    function harvest(uint256 tokenId, address to) external returns (uint256 reward);
    function withdraw(uint256 tokenId, address to) external returns (uint256 reward);
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}
