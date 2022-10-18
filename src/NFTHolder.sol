// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./modules/IModule.sol";

import "./external/openzeppelin/access/Ownable.sol";
import "./external/openzeppelin/token/ERC721/IERC721Receiver.sol";
import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract NFTHolder is IERC721Receiver, Ownable  {

    uint32 constant public MAX_TOKENS_PER_ADDRESS = 100;

    // uniswap v3 components
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }
    
    struct Module {
        IModule implementation; // 160 bits
        bool checkAllowCollect; // to avoid calling contract when not needed
    }

    uint public modulesCount;
    mapping(uint256 => Module) public modules;
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
        // must be approved
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, "");
         _addToken(tokenId, msg.sender, initialModules);
    }

    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external {

        address owner = tokenOwners[tokenId];

        require(to != address(this), "to==this");
        require(owner == msg.sender, "!owner");
        
        _removeToken(tokenId, msg.sender);
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    function balanceOf(address account) external view returns (uint) {
        return accountTokens[account].length;
    }

    function addTokenToModule(uint256 tokenId, uint8 module) external {
        require(tokenOwners[tokenId] == msg.sender, "!owner");
        require(tokenModules[tokenId] & 1 << module == 0, "already active");

        modules[module].addToken(tokenId, msg.sender);
        tokenModules[tokenId] = tokenModules[tokenId] | 1 << module;
    }

    function removeTokenFromModule(uint256 tokenId, uint8 module) external {
        require(tokenOwners[tokenId] == msg.sender, "!owner");
        require(tokenModules[tokenId] & 1 << module != 0, "not active");

        modules[module].withdrawToken(tokenId, msg.sender);
        tokenModules[tokenId] = tokenModules[tokenId] | 1 << module;
    }

    function registerModule(IModule module) external onlyOwner {
        require(address(module) != address(0), "must be not 0");
        modules[moduleCount] = module;
        moduleCount++;
    }

    function _addToken(uint tokenId, address account, uint initialModules) internal {

        require(accountTokens[account].length < MAX_TOKENS_PER_ADDRESS, "max tokens reached");

        accountTokens[account].push(tokenId);
        tokenOwners[tokenId] = account;
        tokenModules[tokenId] = initialModules;

        uint maxIndex = modulesCount;
        uint index = 0;
        while(initialModules > 0) {
            if (index >= maxIndex) {
                revert("not existing module");
            }
            if (initialModules & 1 << index != 0) {
                modules[index].addToken(tokenId, account);
                initialModules -= 1 << index;
            }
            index++;
        }
    }

    function _removeToken(uint256 tokenId, address account) internal {

        // withdraw from all active modules
        uint mod = tokenModules[tokenId];
        uint maxIndex = modulesCount;
        uint index = 0;
        while(mod > 0) {
            if (index >= maxIndex) {
                revert("not existing module");
            }
            if (mod & 1 << index != 0) {
                modules[index].withdrawToken(tokenId, account);
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

    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 amount0;
        uint256 amount1;
        uint256 deadline;
        address recipient;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params)  
        external
        returns (uint256 amount0, uint256 amount1) 
    {
        // check if collect allowed by all modules of this position with checkAllowCollect

        // check if user or module

        // copy code
    }
}