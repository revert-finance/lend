// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./modules/IModule.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract NFTHolder is IERC721Receiver, Ownable  {

    uint constant public MAX_TOKENS_PER_ADDRESS = 100;

    // wrapped native token address
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    // errors
    error WrongNFT();
    error Unauthorized();
    error MaxTokensReached();
    error ModuleZero();
    error ModuleInactive();
    error ModuleNotExists();
    error ModuleAlreadyRegistered();

    error ModuleAddFail(uint8 index);
    error ModuleWithdrawFail(uint8 index);
    error ModuleCollectCheckFail(uint8 index);

    error TokenNotInModule();
    error InvalidWithdrawTarget();

    // events
    event AddedModule(uint8 index, IModule implementation);
    event SetModuleActive(uint8 index, bool isActive);
    event AddedPositionToModule(uint indexed tokenId, uint8 index, bytes data);
    event RemovedPositionFromModule(uint indexed tokenId, uint8 index);

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

    // generic module params
    struct ModuleParams {
        uint8 index;
        bytes data; // custom data to be passed to module on add / update
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {

        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongNFT();
        }

        ModuleParams[] memory initialModules;
        if (data.length > 0) {
            initialModules = abi.decode(data, (ModuleParams[]));
        }
        _addToken(tokenId, from, initialModules);
        return IERC721Receiver.onERC721Received.selector;
    }

    function addToken(uint256 tokenId, ModuleParams[] memory initialModules) external {
        // must be approved beforehand
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(initialModules));
    }

    function withdrawToken(uint256 tokenId, address to, bytes memory data) external {
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        if(to == address(this)) {
            revert InvalidWithdrawTarget();
        }
        
        _removeToken(tokenId, msg.sender);
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    function balanceOf(address account) external view returns (uint) {
        return accountTokens[account].length;
    }

    function addTokenToModule(uint256 tokenId, ModuleParams calldata params) external {

        Module storage module = modules[params.index];

        if(address(module.implementation) == address(0)) {
            revert ModuleNotExists();
        }
        if (!module.active) {
            revert ModuleInactive();
        }
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }

        // can be called multiple times to update config, modules must handle this case
        module.implementation.addToken(tokenId, msg.sender, params.data);
        emit AddedPositionToModule(tokenId, params.index, params.data);

        tokenModules[tokenId] = tokenModules[tokenId] | (1 << params.index);
    }

    function removeTokenFromModule(uint256 tokenId, uint8 moduleIndex) external {

        Module storage module = modules[moduleIndex];

        if(address(module.implementation) == address(0)) {
            revert ModuleNotExists();
        }
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        if (tokenModules[tokenId] & (1 << moduleIndex) == 0) {
            revert TokenNotInModule();
        }
        if (!module.implementation.withdrawToken(tokenId, msg.sender)) {
             revert ModuleWithdrawFail(moduleIndex);
        }
        emit RemovedPositionFromModule(tokenId, moduleIndex);
        tokenModules[tokenId] -= (1 << moduleIndex);
    }

    /// @notice Adds a new module to the holder
    function addModule(Module calldata module) external onlyOwner returns(uint8) {
        if(address(module.implementation) == address(0)) {
            revert ModuleZero();
        }
        if(modulesIndex[address(module.implementation)] > 0) {
            revert ModuleAlreadyRegistered();
        }

        uint8 moduleIndex = ++modulesCount; // overflows when all registered

        modules[modulesCount] = module;
        modulesIndex[address(module.implementation)] = moduleIndex;

        emit AddedModule(moduleIndex, module.implementation);

        return moduleIndex;
    }

    /// @notice Sets module in active or inactive state
    // When a module is inactive, no more new positions can be added to it
    function setModuleActive(uint8 moduleIndex, bool isActive) external onlyOwner {
        Module storage module = modules[moduleIndex];
        if (address(module.implementation) == address(0)) {
            revert ModuleNotExists();
        }
        module.active = isActive;
        emit SetModuleActive(moduleIndex, isActive);
    }

    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity; // set to exact liquidity to be removed - 0 if only collect fees
        uint256 amount0Min;
        uint256 amount1Min;
        uint128 amountFees0Max; // set to uint128.max for all fees (+ all liquidity removed)
        uint128 amountFees1Max; // set to uint128.max for all fees (+ all liquidity removed)
        uint256 deadline;
        address recipient;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {

        uint mod = tokenModules[params.tokenId];
        uint8 moduleIndex = modulesIndex[msg.sender];
        bool callFromActiveModule = moduleIndex > 0 && (mod & (1 << moduleIndex) != 0);
        address owner = tokenOwners[params.tokenId];

        if (owner != msg.sender && !callFromActiveModule) {
            revert Unauthorized();
        }

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

        uint8 index = 1;
        while(mod > 0) {
            if (mod & (1 << index) != 0) {
                if (index != moduleIndex && modules[index].checkOnCollect) {
                    if (!modules[index].implementation.checkOnCollect(params.tokenId, owner, params.liquidity, amount0, amount1)) {
                        revert ModuleCollectCheckFail(index);
                    }
                }
                mod -= (1 << index);
            }
            index++;
        }
    }

    function _addToken(uint tokenId, address account, ModuleParams[] memory initialModules) internal {

        if (accountTokens[account].length >= MAX_TOKENS_PER_ADDRESS) {
            revert MaxTokensReached();
        }

        accountTokens[account].push(tokenId);
        tokenOwners[tokenId] = account;
        uint i;
        uint mod = 0;
        for (; i < initialModules.length; i++) {
            mod += 1 << initialModules[i].index;
            if (!modules[initialModules[i].index].implementation.addToken(tokenId, account, initialModules[i].data)) {
                revert ModuleAddFail(initialModules[i].index);
            }
        }

        tokenModules[tokenId] = mod;
    }

    function _removeToken(uint256 tokenId, address account) internal {

        // withdraw from all registered modules
        uint mod = tokenModules[tokenId];

        uint8 index = 1;
        while(mod > 0) {
            if (mod & (1 << index) != 0) {
                if (!modules[index].implementation.withdrawToken(tokenId, account)) {
                    revert ModuleWithdrawFail(index);
                }
                emit RemovedPositionFromModule(tokenId, index);
                mod -= (1 << index);
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

