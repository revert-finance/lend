// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./modules/IModule.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";


/// @title IHolder
/// @notice Main container contract for v3 positions, manages modules and access to the v3 positions based on active modules.
interface IHolder is IERC721Receiver {

    struct Module {
        IModule implementation; // 160 bits
        uint256 blocking; // bitmap of modules which when active for the position don't allow the position to enter this module - if module is blocking itself -> deactivated
    }

    function modulesCount() external view returns (uint8);
    //function modules(uint8 moduleIndex) external view returns (Module memory);
    function modulesIndex(address implementation) external view returns (uint8);

    function tokenOwners(uint256 tokenId) external view returns (address);
    function tokenModules(uint256 tokenId) external view returns (uint256);
    //function accountTokens(address account) external view returns (int256[] memory);

    // generic module params
    struct ModuleParams {
        uint8 index;
        bytes data; // custom data to be passed to module on add / update
    }

    function addToken(uint256 tokenId, ModuleParams[] memory initialModules) external;
    function withdrawToken(uint256 tokenId, address to, bytes memory data) external;
    function balanceOf(address account) external view returns (uint256);
    function getModuleTokensForOwner(address owner, address module) external view returns (uint256[] memory tokens);
    function addTokenToModule(uint256 tokenId, ModuleParams calldata params) external;
    function removeTokenFromModule(uint256 tokenId, uint8 moduleIndex) external;
    function addModule( IModule implementation, uint256 blocking) external returns (uint8);
    function setModuleBlocking(uint8 moduleIndex, uint256 blocking) external;

    function registerFutureOwner(address owner) external;

    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity; // set to exact liquidity to be removed - 0 if only collect fees
        uint256 amount0Min;
        uint256 amount1Min;
        uint128 amountFees0Max; // set to uint128.max for all fees (+ all liquidity removed)
        uint128 amountFees1Max; // set to uint128.max for all fees (+ all liquidity removed)
        uint256 deadline;
        bool unwrap;
        address recipient;
        bytes callbackData; // data which is sent to callback
    }
    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1, bytes memory callbackReturnData);
}