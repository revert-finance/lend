// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./modules/IModule.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract NFTHolder is IERC721Receiver, Ownable  {

    uint constant public MAX_TOKENS_PER_ADDRESS = 100;

    // uniswap v3 components
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }
    
    struct Module {
        IModule implementation; // 160 bits
        bool active; // allows to add new positions
        bool checkOnCollect; // this module needs to check if collect allowed by other modules / owner
    }

    uint8 public modulesCount;
    mapping(uint8 => Module) public modules;
    mapping(address => uint8) public modulesIndex;
    
    mapping(uint256 => address) public tokenOwners;
    mapping(uint256 => uint256) public tokenModules;
    mapping(address => uint256[]) public accountTokens;

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {
        uint initialModules = abi.decode(data, (uint));
        _addToken(tokenId, from, initialModules);
        return IERC721Receiver.onERC721Received.selector;
    }

    function addToken(uint256 tokenId, uint256 initialModules) external {
        // must be approved beforehand
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(initialModules));
    }

    function withdrawToken(uint256 tokenId, address to, bytes memory data) external {

        require(tokenOwners[tokenId] == msg.sender, "!owner");
        require(to != address(this), "to==this");
        
        _removeToken(tokenId, msg.sender);
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    function balanceOf(address account) external view returns (uint) {
        return accountTokens[account].length;
    }

    function addTokenToModule(uint256 tokenId, uint8 module) external {
        require(tokenOwners[tokenId] == msg.sender, "!owner");
        require(tokenModules[tokenId] & 1 << module == 0, "already active");

        modules[module].implementation.addToken(tokenId, msg.sender);
        tokenModules[tokenId] = tokenModules[tokenId] | 1 << module;
    }

    function removeTokenFromModule(uint256 tokenId, uint8 module) external {
        require(tokenOwners[tokenId] == msg.sender, "!owner");
        require(tokenModules[tokenId] & 1 << module != 0, "not active");

        modules[module].implementation.withdrawToken(tokenId, msg.sender);
        tokenModules[tokenId] = tokenModules[tokenId] | 1 << module;
    }

    function registerModule(Module calldata module) external onlyOwner {
        require(address(module.implementation) != address(0), "implementation == 0");
        require(modulesIndex[address(module.implementation)] == 0, "already registered");
        require(modulesCount < type(uint8).max, "modules maxxed out");

        modulesCount++;
        modules[modulesCount] = module;
        modulesIndex[address(module.implementation)] = modulesCount;
    }

    function deprecateModule(uint8 module) external onlyOwner {
        require(module > 0 && module <= modulesCount, "invalid module");
        require(modules[module].active, "!active");
        modules[module].active = false;
    }

    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint128 amountFees0Max;
        uint128 amountFees1Max;
        uint256 deadline;
        address recipient;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {

        uint mod = tokenModules[params.tokenId];
        uint8 moduleIndex = modulesIndex[msg.sender];
        bool callFromActiveModule = moduleIndex > 0 && (mod & (1 << moduleIndex) != 0);
        require(callFromActiveModule || tokenOwners[params.tokenId] == msg.sender, "!owner");

        if (params.liquidity > 0) {
            (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    params.tokenId, 
                    params.liquidity, 
                    params.amount0Min, 
                    params.amount1Min,
                    params.deadline
                )
            );
        }

        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId,
                params.recipient,
                params.amountFees0Max > amount0 ? params.amountFees0Max : _toUint128(amount0),
                params.amountFees1Max > amount1 ? params.amountFees1Max : _toUint128(amount1)
            )
        );

        //TODO check if each active modules allows collect
    }

    function _addToken(uint tokenId, address account, uint initialModules) internal {

        require(accountTokens[account].length < MAX_TOKENS_PER_ADDRESS, "max tokens reached");

        accountTokens[account].push(tokenId);
        tokenOwners[tokenId] = account;
        tokenModules[tokenId] = initialModules;

        uint maxIndex = modulesCount;
        uint8 index = 0;
        while(initialModules > 0) {
            if (index >= maxIndex) {
                revert("not existing module");
            }
            if (initialModules & 1 << index != 0) {
                modules[index].implementation.addToken(tokenId, account);
                initialModules -= 1 << index;
            }
            index++;
        }
    }

    function _removeToken(uint256 tokenId, address account) internal {

        // withdraw from all active modules
        uint mod = tokenModules[tokenId];
        uint maxIndex = modulesCount;
        uint8 index = 0;
        while(mod > 0) {
            if (index >= maxIndex) {
                revert("not existing module");
            }
            if (mod & 1 << index != 0) {
                modules[index].implementation.withdrawToken(tokenId, account);
                mod -= 1 << index;
            }
            index++;
        }

        uint256[] memory accountTokensArr = accountTokens[account];
        uint256 len = accountTokensArr.length;
        uint256 assetIndex = len;

        // limited by MAX_POSITIONS_PER_ADDRESS (no out-of-gas problem)
        for (uint256 i = 0; i < len; i++) {
            if (accountTokensArr[i] == tokenId) {
                assetIndex = i;
                break;
            }
        }

        uint256[] storage storedList = accountTokens[account];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        delete tokenOwners[tokenId];
        delete tokenModules[tokenId];
    }

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }
}