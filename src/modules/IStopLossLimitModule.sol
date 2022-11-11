// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

interface IStopLossLimitModule is IModule {
   
    // config changes
    event RewardUpdated(address account, uint64 protocolRewardX64);

    // stop loss / limit event
    event Executed(
        address account,
        bool isSwap,
        uint256 tokenId,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1
    );

    /// @notice Reward which is payed to compounder - less or equal to totalRewardX64
    function protocolRewardX64() external view returns (uint64);

    /// @notice Max tick difference between TWAP tick and current price to allow operations
    function maxTWAPTickDifference() external view returns (uint32);

    /// @notice Number of seconds to use for TWAP calculation
    function TWAPSeconds() external view returns (uint32);
}
