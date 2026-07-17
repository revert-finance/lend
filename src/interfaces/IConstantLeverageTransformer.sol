// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IConstantLeverageTransformer {
    /// @notice Configuration for a position's constant leverage strategy
    struct LeverageConfig {
        uint16 targetLeverageBps; // Target debt/collateral ratio in bps (e.g., 5000 = 50% = 2x leverage)
        uint16 lowerThresholdBps; // Trigger increase when below target by this amount
        uint16 upperThresholdBps; // Trigger decrease when above target by this amount
        uint64 maxSlippageX64; // Max slippage from oracle price (e.g., 1% = Q64 / 100)
        bool onlyFees; // If true, protocol reward only taken from collected fees
        uint64 maxRewardX64; // Max reward percentage for this position (Q64)
    }

    /// @notice Parameters for rebalance execution
    struct RebalanceParams {
        uint256 tokenId;
        uint256 swapAmount0; // Amount of token0 to swap (0 = no swap)
        bytes swapData0; // Router swap data for token0
        uint256 swapAmount1; // Amount of token1 to swap (0 = no swap)
        bytes swapData1; // Router swap data for token1
        uint256 deadline;
        uint64 rewardX64; // Reward to take (must be <= config.maxRewardX64)
    }

    /// @notice Emitted when a position config is set
    event PositionConfigured(
        uint256 indexed tokenId,
        uint16 targetLeverageBps,
        uint16 lowerThresholdBps,
        uint16 upperThresholdBps,
        uint64 maxSlippageX64,
        bool onlyFees,
        uint64 maxRewardX64
    );

    /// @notice Emitted when a position is rebalanced
    event Rebalanced(
        uint256 indexed tokenId,
        bool isIncrease,
        uint256 debtBefore,
        uint256 debtAfter,
        uint256 reward0,
        uint256 reward1
    );

    /// @notice Set configuration for a position
    /// @param tokenId The NFT token ID
    /// @param vault The vault address where the position is held
    /// @param config The leverage configuration
    function setPositionConfig(uint256 tokenId, address vault, LeverageConfig calldata config) external;

    /// @notice Check if a position needs rebalancing
    /// @param tokenId The NFT token ID
    /// @param vault The vault address
    /// @return needed Whether rebalance is needed
    /// @return isIncrease Whether leverage should increase (true) or decrease (false)
    /// @return currentRatioBps Current debt/collateral ratio in bps
    function checkRebalanceNeeded(uint256 tokenId, address vault)
        external
        view
        returns (bool needed, bool isIncrease, uint256 currentRatioBps);

    /// @notice Execute rebalance (only callable by vault via transform)
    /// @dev Operators must use rebalanceWithVault() - direct calls will revert
    /// @param params Rebalance parameters
    function rebalance(RebalanceParams calldata params) external;

    /// @notice Execute rebalance via vault transform
    /// @param params Rebalance parameters
    /// @param vault The vault address
    function rebalanceWithVault(RebalanceParams calldata params, address vault) external;
}
