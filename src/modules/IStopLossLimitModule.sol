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
        bool isLimit,
        uint256 tokenId,
        uint256 amountReturned0,
        uint256 amountReturned1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );
}
