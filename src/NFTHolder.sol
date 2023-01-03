// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./modules/IModule.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

/// @title NFTHolder
/// @notice Main container contract for v3 positions, manages modules and access to the v3 positions based on active modules.
contract NFTHolder is IERC721Receiver, Ownable {
    uint256 public constant MAX_TOKENS_PER_ADDRESS = 20;

    // wrapped native token address
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    // errors
    error WrongContract();
    error Unauthorized();
    error MaxTokensReached();
    error ModuleZero();
    error ModuleInactive();
    error ModuleBlocked();
    error ModuleNotExists();
    error ModuleAlreadyRegistered();
    error TokenNotReturned();
    error FlashTransformNotConfigured();
    error FlashTransformInProgress();
    error NoFlashTransformInProgress();
    error TokenNotInModule();
    error InvalidWithdrawTarget();
    error InvalidFromAddress();

    // events
    event AddedModule(uint8 index, IModule implementation);
    event SetModuleBlocking(uint8 index, uint256 blocking);
    event SetFlashTransformContract(address flashTransformContract);
    event AddedPositionToModule(
        uint256 indexed tokenId,
        uint8 index,
        bytes data
    );
    event RemovedPositionFromModule(uint256 indexed tokenId, uint8 index);

    constructor(INonfungiblePositionManager _nonfungiblePositionManager) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }

    uint256 public checkOnCollect; // bitmap with modules that need check on collect
    address public flashTransformContract; // contract which is allowed to do flash transforms
    uint256 flashTransformedTokenId; // store tokenid which is flash transformed

    struct Module {
        IModule implementation; // 160 bits
        uint256 blocking; // bitmap of modules which when active for the position don't allow the position to enter this module - if module is blocking itself -> deactivated
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

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        ModuleParams[] memory initialModules;

        // if flashTransform contract sent token back - special handling
        if (from == flashTransformContract) {
            uint flashTokenId = flashTransformedTokenId;
            // if its called from minting context
            if (flashTokenId == 0) {
                bytes memory returnData;
                // set owner to caller of minting context
                (from, returnData) = abi.decode(data, (address, bytes));
                if (from == address(0)) {
                    revert InvalidFromAddress();
                }
                if (returnData.length > 0) {
                    initialModules = abi.decode(returnData, (ModuleParams[]));
                }
            } else {
                if (tokenId == flashTokenId) {
                     // its the same token - no need to do nothing here
                    return IERC721Receiver.onERC721Received.selector;
                } else {
                    // its another token - assume it belongs to flash transformed tokens owner
                    from = tokenOwners[flashTransformedTokenId];
                }
                if (data.length > 0) {
                    initialModules = abi.decode(data, (ModuleParams[]));
                }
            }
        } else {
            if (data.length > 0) {
                initialModules = abi.decode(data, (ModuleParams[]));
            }
        }
    
        _addToken(tokenId, from, initialModules);
        return IERC721Receiver.onERC721Received.selector;
    }

    function addToken(uint256 tokenId, ModuleParams[] memory initialModules) external {
        // must be approved beforehand
        nonfungiblePositionManager.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            abi.encode(initialModules)
        );
    }

    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external {
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        if (to == address(this) || to == address(0)) {
            revert InvalidWithdrawTarget();
        }
        _removeToken(tokenId, msg.sender);
        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            to,
            tokenId,
            data
        );
    }

    function balanceOf(address account) external view returns (uint256) {
        return accountTokens[account].length;
    }

    // gets all tokens which are active for a given module address
    function getModuleTokensForOwner(address owner, address module)
        external
        view
        returns (uint256[] memory tokens)
    {
        uint8 moduleIndex = modulesIndex[module];
        if (moduleIndex == 0) {
            revert ModuleNotExists();
        }

        uint256 count = accountTokens[owner].length;
        uint256 total;
        uint256 i;
        uint256 mod = (1 << moduleIndex);
        for (; i < count; i++) {
            if (tokenModules[accountTokens[owner][i]] & mod > 0) {
                total++;
            }
        }
        tokens = new uint256[](total);
        i = 0;
        for (; i < count; i++) {
            if (tokenModules[accountTokens[owner][i]] & mod > 0) {
                tokens[--total] = accountTokens[owner][i];
            }
        }
    }

    function addTokenToModule(uint256 tokenId, ModuleParams calldata params)
        external
    {
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }

        Module storage module = modules[params.index];
        if (address(module.implementation) == address(0)) {
            revert ModuleNotExists();
        }

        uint256 newTokenModules = tokenModules[tokenId] | (1 << params.index);
        if (module.blocking & newTokenModules > 0) {
            revert ModuleBlocked();
        }

        // can be called multiple times to update config, modules must handle this case
        module.implementation.addToken(tokenId, msg.sender, params.data);
        emit AddedPositionToModule(tokenId, params.index, params.data);
        tokenModules[tokenId] = newTokenModules;
    }

    function removeTokenFromModule(uint256 tokenId, uint8 moduleIndex)
        external
    {
        if (tokenOwners[tokenId] != msg.sender) {
            revert Unauthorized();
        }

        uint256 tokenMods = tokenModules[tokenId];
        if (tokenMods & (1 << moduleIndex) == 0) {
            revert TokenNotInModule();
        }

        Module storage module = modules[moduleIndex];
        module.implementation.withdrawToken(tokenId, msg.sender);
        emit RemovedPositionFromModule(tokenId, moduleIndex);
        tokenModules[tokenId] = tokenMods - (1 << moduleIndex);
    }

    /// @notice Adds a new module to the holder
    function addModule(
        IModule implementation,
        uint256 blocking
    ) external onlyOwner returns (uint8) {
        if (address(implementation) == address(0)) {
            revert ModuleZero();
        }
        if (modulesIndex[address(implementation)] > 0) {
            revert ModuleAlreadyRegistered();
        }

        uint8 moduleIndex = ++modulesCount; // overflows when all registered

        modules[modulesCount] = Module(implementation, blocking);
        modulesIndex[address(implementation)] = moduleIndex;

        // add to checkoncollect flags if needed
        if (implementation.needsCheckOnCollect()) {
            checkOnCollect += (1 << moduleIndex);
        }

        emit AddedModule(moduleIndex, implementation);

        return moduleIndex;
    }

    /// @notice Sets module blocking configuration
    // When a position is in a module which is in blocking bitmap it cant be added to this module
    // Adding a modules index to its own blocking bitmap - disables adding new positions to the module
    function setModuleBlocking(uint8 moduleIndex, uint256 blocking) external onlyOwner
    {
        Module storage module = modules[moduleIndex];
        if (address(module.implementation) == address(0)) {
            revert ModuleNotExists();
        }
        module.blocking = blocking;
        emit SetModuleBlocking(moduleIndex, blocking);
    }


    /// @notice Sets new flash transform contract
    function setFlashTransformContract(address _flashTransformContract) external onlyOwner
    {
        flashTransformContract = _flashTransformContract;
        emit SetFlashTransformContract(_flashTransformContract);
    }

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

    /// @notice flash transforms token - must be returned afterwards
    /// only token owner is allowed to call this!!
    /// currently used vor v3utils type of operations, data is encoded Instructions for V3Utils
    function flashTransform(uint256 tokenId, bytes calldata data) external {
        if (flashTransformedTokenId > 0) {
            revert FlashTransformInProgress();
        }
        flashTransformedTokenId = tokenId;

        address owner = tokenOwners[tokenId];
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (flashTransformContract == address(0)) {
            revert FlashTransformNotConfigured();
        }
        
        // do transfer to flash transform contract
        nonfungiblePositionManager.safeTransferFrom(address(this), flashTransformContract, tokenId, data);

        // must have been returned afterwards
        if (nonfungiblePositionManager.ownerOf(tokenId) != address(this)) {
            revert TokenNotReturned();
        }

        // only allow if complete collect is allowed by all modules involved
        uint256 mod = tokenModules[tokenId];
        _checkOnCollect(0, mod, tokenId, owner, type(uint128).max, type(uint128).max, type(uint128).max);
    
        // reset flash transformed token
        flashTransformedTokenId = 0;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params) external returns (uint256 amount0, uint256 amount1, bytes memory callbackReturnData) {
        uint256 mod = tokenModules[params.tokenId];
        uint8 moduleIndex = modulesIndex[msg.sender];
        bool callFromActiveModule = moduleIndex > 0 &&
            (mod & (1 << moduleIndex) != 0);
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
                amount0 + params.amountFees0Max >= type(uint128).max ? type(uint128).max : _toUint128(amount0 + params.amountFees0Max),
                amount1 + params.amountFees1Max >= type(uint128).max ? type(uint128).max : _toUint128(amount1 + params.amountFees1Max)
            )
        );

        // if call is from module - execute callback - for code that needs to be run before _checkOnCollect is run
        if (moduleIndex > 0) {
            callbackReturnData = modules[moduleIndex].implementation.decreaseLiquidityAndCollectCallback(
                    params.tokenId,
                    amount0,
                    amount1,
                    params.callbackData
                );
        }

        _checkOnCollect(moduleIndex, mod, params.tokenId, owner, params.liquidity, amount0, amount1);
    }

    function _checkOnCollect(uint8 moduleIndex, uint256 mod, uint256 tokenId, address owner, uint128 liquidity, uint fees0, uint fees1) internal {
        
        // check all modules which need to be checked at the end
        uint8 index = 1;
        uint256 check = checkOnCollect;
        while (mod > 0) {
            if (mod & (1 << index) > 0) {
                // module to be checked must be different from calling module and in check bitmap
                if (moduleIndex != index && check & (1 << index) > 0) {
                    modules[index].implementation.checkOnCollect(
                        tokenId,
                        owner,
                        liquidity,
                        fees0,
                        fees1
                    );
                }
                mod -= (1 << index);
            }
            index++;
        }
    }

    function _addToken(
        uint256 tokenId,
        address account,
        ModuleParams[] memory initialModules
    ) internal {
        if (accountTokens[account].length >= MAX_TOKENS_PER_ADDRESS) {
            revert MaxTokensReached();
        }

        accountTokens[account].push(tokenId);
        tokenOwners[tokenId] = account;
        uint256 i;
        for (; i < initialModules.length; i++) {
            tokenModules[tokenId] += 1 << initialModules[i].index;
            modules[initialModules[i].index].implementation.addToken(
                tokenId,
                account,
                initialModules[i].data
            );
        }
    }

    function _removeToken(uint256 tokenId, address account) internal {
        // withdraw from all registered modules
        uint256 mod = tokenModules[tokenId];

        uint8 index = 1;
        while (mod > 0) {
            if (mod & (1 << index) != 0) {
                modules[index].implementation.withdrawToken(tokenId, account);
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
        require((y = uint128(x)) == x, "uint128 cast error");
    }
}