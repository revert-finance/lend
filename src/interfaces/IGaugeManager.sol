// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IGaugeManager {
    // Events
    event PositionStaked(uint256 indexed tokenId, address indexed owner);
    event PositionUnstaked(uint256 indexed tokenId, address indexed owner);
    event RewardsCompounded(uint256 indexed tokenId, uint256 aeroAmount, uint256 amount0, uint256 amount1);
    event RewardsAccumulated(address indexed owner, uint256 amount);
    event SwapAndIncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V3UtilsSet(address indexed v3Utils);
    event PositionMigratedToVault(uint256 indexed tokenId, address indexed owner);
    event PositionTransformed(uint256 indexed oldTokenId, uint256 indexed newTokenId, address indexed owner);
    event TransformerSet(address indexed transformer, bool active);
    event ApprovedTransform(uint256 indexed tokenId, address indexed owner, address indexed transformer, bool isActive);
    event RewardUpdated(address account, uint64 totalRewardX64);
    event FeeWithdrawerUpdated(address withdrawer);
    event FeesWithdrawn(address token, address to, uint256 amount);

    // Core functions
    function stakePosition(uint256 tokenId) external;
    function unstakePosition(uint256 tokenId) external;
    
    // Compounding
    function compoundRewards(
        uint256 tokenId,
        bytes calldata swapData0,
        bytes calldata swapData1,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external;
    
    // Simple claim without compounding
    function claimRewards(uint256 tokenId) external;

    // Claim accumulated rewards (PULL pattern)
    function claimAccumulatedRewards(address recipient) external returns (uint256);
    
    // Position management with V3Utils
    function executeV3UtilsWithOptionalCompound(
        uint256 tokenId,
        bytes memory instructions, // V3Utils.Instructions
        bool shouldCompound,
        bytes memory aeroSwapData0,
        bytes memory aeroSwapData1,
        uint256 minAeroAmount0,
        uint256 minAeroAmount1,
        uint256 aeroSplitBps
    ) external returns (uint256 newTokenId);
    
    // Add liquidity to staked position
    function swapAndIncreaseStakedPosition(
        uint256 tokenId,
        bytes calldata params // V3Utils.SwapAndIncreaseLiquidityParams
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    
    // Migrate to vault
    function migrateToVault(uint256 tokenId, address recipient) external;
    
    // Transform approvals
    function approveTransform(uint256 tokenId, address transformer, bool isActive) external;
    
    // Operator management
    function setOperator(address operator, bool approved) external;
    
    // Transform function for AutoRange integration
    function transform(uint256 tokenId, address transformer, bytes calldata data) external returns (uint256 newTokenId);
    
    // View functions
    function positionOwners(uint256 tokenId) external view returns (address);
    function isVaultPosition(uint256 tokenId) external view returns (bool);
    function tokenIdToGauge(uint256 tokenId) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
    function operators(address user, address operator) external view returns (bool);
    function aeroToken() external view returns (address);
    function vault() external view returns (address);
    function v3Utils() external view returns (address);
    function totalRewardX64() external view returns (uint64);
    function feeWithdrawer() external view returns (address);
    function transformerAllowList(address transformer) external view returns (bool);
    function transformApprovals(address owner, uint256 tokenId, address transformer) external view returns (bool);
    function unclaimedRewards(address owner) external view returns (uint256);
    
    // Admin functions
    function setGauge(address pool, address gauge) external;
    function setTransformer(address transformer, bool active) external;
    function setV3Utils(address payable _v3Utils) external;
    function setReward(uint64 _totalRewardX64) external;
    function setFeeWithdrawer(address _feeWithdrawer) external;
    function withdrawFees(address[] calldata tokens, address to) external;
}