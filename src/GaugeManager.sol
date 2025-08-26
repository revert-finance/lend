// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "./interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "./interfaces/aerodrome/IGauge.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IV3Utils.sol";
import "./utils/Constants.sol";
import "./utils/Swapper.sol";

/// @title GaugeManager with Built-in Compounding
/// @notice Single contract that handles both staking AND compounding
/// @dev Simplest solution - one contract does everything
contract GaugeManager is Ownable2Step, IERC721Receiver, ReentrancyGuard, Swapper {
    using SafeERC20 for IERC20;

    event PositionStaked(uint256 indexed tokenId, address indexed owner);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner);
    event RewardsCompounded(uint256 indexed tokenId, uint256 aeroAmount, uint256 amount0, uint256 amount1);
    event SwapAndIncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V3UtilsSet(address indexed v3Utils);
    event PositionMigratedToVault(uint256 indexed tokenId, address indexed owner);

    IERC20 public immutable aeroToken;
    IVault public immutable vault;
    
    // V3Utils for position management operations
    address public v3Utils;

    // Core mappings
    mapping(address => address) public poolToGauge;
    mapping(uint256 => address) public tokenIdToGauge;
    mapping(uint256 => address) public positionOwners;
    mapping(uint256 => bool) public isVaultPosition;
    
    // Operator system for auto-compounding
    mapping(address => mapping(address => bool)) public operators;

    constructor(
        IAerodromeNonfungiblePositionManager _npm,
        IERC20 _aeroToken,
        IVault _vault,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(
        INonfungiblePositionManager(address(_npm)),
        _universalRouter,
        _zeroxAllowanceHolder
    ) Ownable2Step() {
        aeroToken = _aeroToken;
        vault = _vault;
    }

    /// @notice Set gauge for a pool
    function setGauge(address pool, address gauge) external onlyOwner {
        poolToGauge[pool] = gauge;
    }

    /// @notice Set operator approval
    function setOperator(address operator, bool approved) external {
        operators[msg.sender][operator] = approved;
    }

    /// @notice Set V3Utils contract address
    function setV3Utils(address _v3Utils) external onlyOwner {
        v3Utils = _v3Utils;
        emit V3UtilsSet(_v3Utils);
    }

    /// @notice Stake a position (works for both vault and direct)
    function stakePosition(uint256 tokenId) external nonReentrant {
        address nftOwner = nonfungiblePositionManager.ownerOf(tokenId);
        
        // Determine if vault or direct position
        bool fromVault = msg.sender == address(vault);
        address owner = fromVault ? IVault(vault).ownerOf(tokenId) : msg.sender;
        
        require(owner != address(0), "Invalid owner");
        require(fromVault || nftOwner == msg.sender, "Not authorized");

        // Get gauge for position
        (,, address token0, address token1, uint24 tickSpacing,,,,,,,) = 
            nonfungiblePositionManager.positions(tokenId);
        address pool = IAerodromeSlipstreamFactory(factory).getPool(token0, token1, int24(tickSpacing));
        address gauge = poolToGauge[pool];
        require(gauge != address(0), "No gauge");

        // Transfer and stake
        nonfungiblePositionManager.safeTransferFrom(nftOwner, address(this), tokenId);
        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);

        // Record ownership
        tokenIdToGauge[tokenId] = gauge;
        positionOwners[tokenId] = owner;
        isVaultPosition[tokenId] = fromVault;

        emit PositionStaked(tokenId, owner);
    }

    /// @notice Unstake a position
    function unstakePosition(uint256 tokenId) external nonReentrant {
        address owner = positionOwners[tokenId];
        bool fromVault = isVaultPosition[tokenId];
        
        // Check authorization
        require(
            (fromVault && msg.sender == address(vault)) ||
            (!fromVault && msg.sender == owner),
            "Not authorized"
        );

        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");

        // Claim final rewards and send to owner
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        
        if (aeroAmount > 0) {
            aeroToken.safeTransfer(owner, aeroAmount);
        }
        
        // Unstake
        IGauge(gauge).withdraw(tokenId);
        
        // Return NFT
        address returnTo = fromVault ? address(vault) : owner;
        nonfungiblePositionManager.safeTransferFrom(address(this), returnTo, tokenId);

        // Clean up
        delete tokenIdToGauge[tokenId];
        delete positionOwners[tokenId];
        delete isVaultPosition[tokenId];

        emit PositionUnstaked(tokenId, owner);
    }

    /// @notice Compound rewards for a position (THE KEY SIMPLIFICATION)
    /// @dev All-in-one: claim, swap, add liquidity
    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) external nonReentrant {
        // Check authorization
        address owner = positionOwners[tokenId];
        bool fromVault = isVaultPosition[tokenId];
        require(
            msg.sender == owner || 
            operators[owner][msg.sender] ||
            (fromVault && msg.sender == address(vault)),
            "Not authorized"
        );

        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");

        // 1. Claim AERO rewards for this specific NFT
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        
        if (aeroAmount == 0) return;

        // 2. Get position details
        (,, address token0, address token1,,,,,,,,) = 
            nonfungiblePositionManager.positions(tokenId);

        // 3. Swap AERO to position tokens
        uint256 amount0;
        uint256 amount1;
        
        if (swapData0.length > 0) {
            (, amount0) = _routerSwap(
                RouterSwapParams(
                    aeroToken,
                    IERC20(token0),
                    (aeroAmount * aeroSplitBps) / 10000,
                    minAmount0,
                    swapData0
                )
            );
        }
        
        if (swapData1.length > 0) {
            (, amount1) = _routerSwap(
                RouterSwapParams(
                    aeroToken,
                    IERC20(token1),
                    aeroToken.balanceOf(address(this)),
                    minAmount1,
                    swapData1
                )
            );
        }

        // 4. Temporarily unstake to add liquidity
        IGauge(gauge).withdraw(tokenId);

        // 5. Add liquidity
        IERC20(token0).safeApprove(address(nonfungiblePositionManager), 0);
        IERC20(token0).safeIncreaseAllowance(address(nonfungiblePositionManager), amount0);
        IERC20(token1).safeApprove(address(nonfungiblePositionManager), 0);
        IERC20(token1).safeIncreaseAllowance(address(nonfungiblePositionManager), amount1);
        
        (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) = 
            nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    amount0,
                    amount1,
                    0,
                    0,
                    deadline
                )
            );

        // 6. Re-stake
        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);

        // 7. Return leftover tokens to position owner
        uint256 leftover0 = amount0 - amount0Added;
        uint256 leftover1 = amount1 - amount1Added;
        
        if (leftover0 > 0) {
            IERC20(token0).safeTransfer(owner, leftover0);
        }
        if (leftover1 > 0) {
            IERC20(token1).safeTransfer(owner, leftover1);
        }

        emit RewardsCompounded(tokenId, aeroAmount, amount0Added, amount1Added);
    }

    /// @notice Simple reward claiming without compounding
    function claimRewards(uint256 tokenId) external nonReentrant {
        address owner = positionOwners[tokenId];
        bool fromVault = isVaultPosition[tokenId];
        
        // Check authorization: owner, operator, or vault can claim
        require(
            msg.sender == owner || 
            operators[owner][msg.sender] ||
            (fromVault && msg.sender == address(vault)),
            "Not authorized"
        );
        
        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");
        
        // Claim and send to owner
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        
        if (aeroAmount > 0) {
            aeroToken.safeTransfer(owner, aeroAmount);
        }
    }

    /// @notice Execute V3Utils operation on staked position with optional AERO compounding
    /// @param tokenId The staked position to operate on
    /// @param instructions V3Utils instructions
    /// @param shouldCompound Whether to compound AERO rewards before restaking
    /// @param aeroSwapData0 Swap data for AERO->token0 if compounding
    /// @param aeroSwapData1 Swap data for AERO->token1 if compounding
    /// @param minAeroAmount0 Min amount of token0 from AERO swap if compounding
    /// @param minAeroAmount1 Min amount of token1 from AERO swap if compounding
    /// @param aeroSplitBps Basis points of AERO to swap to token0 (rest goes to token1)
    function executeV3UtilsWithOptionalCompound(
        uint256 tokenId,
        IV3Utils.Instructions memory instructions,
        bool shouldCompound,
        bytes memory aeroSwapData0,
        bytes memory aeroSwapData1,
        uint256 minAeroAmount0,
        uint256 minAeroAmount1,
        uint256 aeroSplitBps
    ) public nonReentrant returns (uint256 newTokenId) {
        require(v3Utils != address(0), "V3Utils not configured");
        
        // Check authorization
        address owner = positionOwners[tokenId];
        bool fromVault = isVaultPosition[tokenId];
        require(
            msg.sender == owner || 
            operators[owner][msg.sender] ||
            (fromVault && msg.sender == address(vault)),
            "Not authorized"
        );

        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");

        // 1. Claim any pending AERO rewards
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;

        // 2. Unstake position from gauge
        IGauge(gauge).withdraw(tokenId);

        // 3. Execute V3Utils operation
        nonfungiblePositionManager.approve(v3Utils, tokenId);
        newTokenId = IV3Utils(v3Utils).execute(tokenId, instructions);

        // Determine which tokenId to work with going forward
        uint256 tokenToStake = newTokenId != 0 ? newTokenId : tokenId;

        // 4. If requested and AERO available, compound it
        if (shouldCompound && aeroAmount > 0) {
            _compoundIntoPosition(
                tokenToStake,
                aeroAmount,
                aeroSwapData0,
                aeroSwapData1,
                minAeroAmount0,
                minAeroAmount1,
                aeroSplitBps,
                instructions.deadline
            );
        } else if (aeroAmount > 0) {
            // Send unclaimed AERO to owner
            aeroToken.safeTransfer(owner, aeroAmount);
        }

        // 5. Restake the position (same gauge - pool doesn't change)
        nonfungiblePositionManager.approve(gauge, tokenToStake);
        IGauge(gauge).deposit(tokenToStake);

        // 6. Update ownership tracking
        if (newTokenId != 0) {
            // Clean up old tokenId
            delete tokenIdToGauge[tokenId];
            delete positionOwners[tokenId];
            delete isVaultPosition[tokenId];
        }
        
        tokenIdToGauge[tokenToStake] = gauge;
        positionOwners[tokenToStake] = owner;
        isVaultPosition[tokenToStake] = fromVault;

        emit PositionStaked(tokenToStake, owner);

        return newTokenId;
    }

    /// @notice Internal function to compound AERO into a position
    function _compoundIntoPosition(
        uint256 tokenId,
        uint256 aeroAmount,
        bytes memory swapData0,
        bytes memory swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 aeroSplitBps,
        uint256 deadline
    ) internal {
        // Get position details
        (,, address token0, address token1,,,,,,,,) = 
            nonfungiblePositionManager.positions(tokenId);

        // Swap AERO to position tokens
        uint256 amount0;
        uint256 amount1;
        
        if (swapData0.length > 0) {
            (, amount0) = _routerSwap(
                RouterSwapParams(
                    aeroToken,
                    IERC20(token0),
                    (aeroAmount * aeroSplitBps) / 10000,
                    minAmount0,
                    swapData0
                )
            );
        }
        
        if (swapData1.length > 0) {
            (, amount1) = _routerSwap(
                RouterSwapParams(
                    aeroToken,
                    IERC20(token1),
                    aeroToken.balanceOf(address(this)),
                    minAmount1,
                    swapData1
                )
            );
        }

        // Add liquidity
        IERC20(token0).safeApprove(address(nonfungiblePositionManager), 0);
        IERC20(token0).safeIncreaseAllowance(address(nonfungiblePositionManager), amount0);
        IERC20(token1).safeApprove(address(nonfungiblePositionManager), 0);
        IERC20(token1).safeIncreaseAllowance(address(nonfungiblePositionManager), amount1);
        
        (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) = 
            nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    amount0,
                    amount1,
                    0,
                    0,
                    deadline
                )
            );

        // Return leftover tokens to position owner
        address owner = positionOwners[tokenId];
        uint256 leftover0 = amount0 - amount0Added;
        uint256 leftover1 = amount1 - amount1Added;
        
        if (leftover0 > 0) {
            IERC20(token0).safeTransfer(owner, leftover0);
        }
        if (leftover1 > 0) {
            IERC20(token1).safeTransfer(owner, leftover1);
        }

        emit RewardsCompounded(tokenId, aeroAmount, amount0Added, amount1Added);
    }

    /// @notice Simplified function to change range on a staked position
    /// @param tokenId The staked position to change range for
    /// @param newFee New pool fee tier
    /// @param newTickLower New lower tick
    /// @param newTickUpper New upper tick
    /// @param liquidityToRemove Amount of liquidity to remove (0 = all)
    /// @param deadline Transaction deadline
    /// @param targetToken Target token for V3Utils swaps (address(0) = no swap)
    /// @param v3SwapData0 Swap data for token0 operations in V3Utils
    /// @param v3SwapData1 Swap data for token1 operations in V3Utils
    /// @param aeroSplitBps Basis points of AERO to swap to token0 if compounding
    /// @param shouldCompound Whether to compound AERO rewards
    function executeChangeRange(
        uint256 tokenId,
        uint24 newFee,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 liquidityToRemove,
        uint256 deadline,
        address targetToken,
        bytes memory v3SwapData0,
        bytes memory v3SwapData1,
        uint256 aeroSplitBps,
        bool shouldCompound
    ) external returns (uint256 newTokenId) {
        // Get current position details
        (,, address token0, address token1,,,,,,,,) = 
            nonfungiblePositionManager.positions(tokenId);
        
        // Build V3Utils instructions for CHANGE_RANGE
        IV3Utils.Instructions memory instructions = IV3Utils.Instructions({
            whatToDo: IV3Utils.WhatToDo.CHANGE_RANGE,
            targetToken: targetToken,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: v3SwapData0,
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: v3SwapData1,
            feeAmount0: type(uint128).max, // Collect all fees
            feeAmount1: type(uint128).max, // Collect all fees
            fee: newFee,
            tickLower: newTickLower,
            tickUpper: newTickUpper,
            liquidity: liquidityToRemove,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: deadline,
            recipient: positionOwners[tokenId], // Send dust to owner
            recipientNFT: address(this), // New NFT comes back to GaugeManager
            unwrap: false,
            returnData: "",
            swapAndMintReturnData: ""
        });
        
        // Execute with no compounding data if not requested
        return executeV3UtilsWithOptionalCompound(
            tokenId,
            instructions,
            shouldCompound,
            "", // aeroSwapData0
            "", // aeroSwapData1
            0,  // minAeroAmount0
            0,  // minAeroAmount1
            aeroSplitBps
        );
    }

    /// @notice Add liquidity to a staked position with optional token swaps
    /// @param tokenId The staked position to add liquidity to
    /// @param params Parameters for V3Utils.swapAndIncreaseLiquidity
    function swapAndIncreaseStakedPosition(
        uint256 tokenId,
        IV3Utils.SwapAndIncreaseLiquidityParams calldata params
    ) external payable nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        require(v3Utils != address(0), "V3Utils not configured");
        
        // Check authorization
        address owner = positionOwners[tokenId];
        bool fromVault = isVaultPosition[tokenId];
        require(
            msg.sender == owner || 
            operators[owner][msg.sender] ||
            (fromVault && msg.sender == address(vault)),
            "Not authorized"
        );
        
        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");
        
        // Get position tokens
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        
        // Handle ETH if sent (wrap to WETH)
        if (msg.value > 0) {
            require(token0 == address(weth) || token1 == address(weth), "No WETH in pair");
            weth.deposit{value: msg.value}();
        }
        
        // Transfer tokens from sender to this contract
        if (params.amount0 > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), params.amount0);
        }
        if (params.amount1 > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), params.amount1);
        }
        
        // Approve V3Utils
        if (params.amount0 > 0) {
            IERC20(token0).safeApprove(v3Utils, 0);
            IERC20(token0).safeIncreaseAllowance(v3Utils, params.amount0);
        }
        if (params.amount1 > 0) {
            IERC20(token1).safeApprove(v3Utils, 0);
            IERC20(token1).safeIncreaseAllowance(v3Utils, params.amount1);
        }
        
        // Unstake position
        IGauge(gauge).withdraw(tokenId);
        
        // Call V3Utils.swapAndIncreaseLiquidity
        (liquidity, amount0, amount1) = IV3Utils(v3Utils).swapAndIncreaseLiquidity(params);
        
        // Restake position
        nonfungiblePositionManager.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);
        
        // Return any leftover tokens to sender
        uint256 leftover0 = IERC20(token0).balanceOf(address(this));
        uint256 leftover1 = IERC20(token1).balanceOf(address(this));
        
        if (leftover0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, leftover0);
        }
        if (leftover1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, leftover1);
        }
        
        emit SwapAndIncreaseLiquidity(tokenId, liquidity, amount0, amount1);
        
        return (liquidity, amount0, amount1);
    }

    /// @notice Migrate a staked position to the vault for collateralized borrowing
    /// @param tokenId The staked position to migrate
    /// @param recipient The recipient address in the vault (usually msg.sender)
    /// @dev This unstakes the position and deposits it into the vault in one transaction
    function migrateToVault(uint256 tokenId, address recipient) external nonReentrant {
        address owner = positionOwners[tokenId];
        require(owner == msg.sender, "Not position owner");
        require(!isVaultPosition[tokenId], "Already a vault position");
        
        address gauge = tokenIdToGauge[tokenId];
        require(gauge != address(0), "Not staked");
        
        // Claim final rewards and send to owner
        uint256 aeroBefore = aeroToken.balanceOf(address(this));
        IGauge(gauge).getReward(tokenId);
        uint256 aeroAmount = aeroToken.balanceOf(address(this)) - aeroBefore;
        
        if (aeroAmount > 0) {
            aeroToken.safeTransfer(owner, aeroAmount);
        }
        
        // Unstake from gauge
        IGauge(gauge).withdraw(tokenId);
        
        // Approve vault to take the NFT
        nonfungiblePositionManager.approve(address(vault), tokenId);
        
        // Transfer to vault using safeTransferFrom with recipient encoded
        nonfungiblePositionManager.safeTransferFrom(
            address(this), 
            address(vault), 
            tokenId, 
            abi.encode(recipient)
        );
        
        // Clean up mappings
        delete tokenIdToGauge[tokenId];
        delete positionOwners[tokenId];
        delete isVaultPosition[tokenId];
        
        emit PositionUnstaked(tokenId, owner);
        emit PositionMigratedToVault(tokenId, owner);
    }

    function onERC721Received(address, address, uint256, bytes calldata) 
        external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
