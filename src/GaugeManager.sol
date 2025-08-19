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

    IERC20 public immutable aeroToken;
    IVault public immutable vault;

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
                    aeroAmount / 2,
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

    function onERC721Received(address, address, uint256, bytes calldata) 
        external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
