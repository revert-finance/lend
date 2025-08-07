// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../automators/Automator.sol";
import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IGaugeManager.sol";
import "../GaugeManager.sol";
import "../interfaces/aerodrome/IGauge.sol";
import "../interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";

/// @title AeroCompound
/// @notice Allows operator of AeroCompound contract to compound AERO rewards from staked positions
/// @dev Works with positions staked in gauges, both inside and outside the vault
/// Claims AERO rewards, swaps them to the position's tokens, and adds liquidity
/// Supports both Universal Router and 0x Protocol for swaps
contract AeroCompound is Automator, Multicall, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events
    event AeroCompounded(
        address indexed account,
        uint256 indexed tokenId,
        uint256 aeroAmount,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );

    event RewardUpdated(address account, uint64 totalRewardX64);
    event BalanceAdded(uint256 tokenId, address token, uint256 amount);
    event BalanceRemoved(uint256 tokenId, address token, uint256 amount);
    event BalanceWithdrawn(uint256 tokenId, address token, address to, uint256 amount);
    event VaultSet(address newVault);

    // Constants
    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 20); // 5% max
    
    // State variables
    IERC20 public immutable aeroToken;
    IGaugeManager public immutable gaugeManager;
    IAerodromeSlipstreamFactory public immutable aerodromeFactory;
    uint64 public totalRewardX64 = uint64(Q64 / 50); // 2% default
    
    // Vaults mapping from Transformer
    mapping(address => bool) public vaults;
    
    // Balances of leftover tokens per position
    mapping(uint256 => mapping(address => uint256)) public positionBalances;
    
    // Track which positions we're authorized to manage (for non-vault positions)
    mapping(uint256 => bool) public authorizedPositions;

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        address _aeroToken,
        address _gaugeManager,
        address _aerodromeFactory
    ) 
        Automator(
            _npm,
            _operator,
            _withdrawer,
            _TWAPSeconds,
            _maxTWAPTickDifference,
            _universalRouter,
            _zeroxAllowanceHolder
        ) 
    {
        aeroToken = IERC20(_aeroToken);
        gaugeManager = IGaugeManager(_gaugeManager);
        aerodromeFactory = IAerodromeSlipstreamFactory(_aerodromeFactory);
    }

    /// @notice Owner controlled function to activate vault address
    function setVault(address _vault) external onlyOwner {
        emit VaultSet(_vault);
        vaults[_vault] = true;
    }

    // Validates if caller is allowed to process position (from Transformer)
    function _validateCaller(INonfungiblePositionManager nonfungiblePositionManager, uint256 tokenId) internal view {
        if (vaults[msg.sender]) {
            uint256 transformedTokenId = IVault(msg.sender).transformedTokenId();
            if (tokenId != transformedTokenId) {
                revert Unauthorized();
            }
        } else {
            address owner = nonfungiblePositionManager.ownerOf(tokenId);
            if (owner != msg.sender && owner != address(this)) {
                revert Unauthorized();
            }
        }
    }

    /// @notice Parameters for execute function
    struct ExecuteParams {
        uint256 tokenId;          // Position to compound
        uint256 minAmount0;       // Min amount of token0 to receive from swap
        uint256 minAmount1;       // Min amount of token1 to receive from swap
        bytes swapData0;          // Swap data for AERO -> token0 (empty if no swap)
        bytes swapData1;          // Swap data for AERO -> token1 (empty if no swap)
        uint256 deadline;         // Deadline for adding liquidity
    }

    /// @notice State used during execution
    struct ExecuteState {
        uint256 aeroAmount;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        address token0;
        address token1;
        uint24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 compounded0;
        uint256 compounded1;
        address gauge;
        bool isVaultPosition;
    }

    /// @notice Execute compounding for a position in vault (called via transform)
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(AeroCompound.execute, (params)));
    }

    /// @notice Execute compounding for a position
    /// @dev Can be called by operator directly or by vault via transform
    function execute(ExecuteParams calldata params) external nonReentrant {
        // Check authorization
        if (!operators[msg.sender]) {
            if (vaults[msg.sender]) {
                _validateCaller(nonfungiblePositionManager, params.tokenId);
            } else {
                revert Unauthorized();
            }
        }

        ExecuteState memory state;
        
        // Determine if position is in vault
        state.isVaultPosition = vaults[nonfungiblePositionManager.ownerOf(params.tokenId)];

        // Get position details
        (,, state.token0, state.token1, state.tickSpacing, state.tickLower, state.tickUpper,,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        // Claim AERO rewards
        if (state.isVaultPosition) {
            // For vault positions, claim through GaugeManager
            uint256 balanceBefore = aeroToken.balanceOf(address(this));
            gaugeManager.claimRewards(params.tokenId);
            gaugeManager.distributeRewards(params.tokenId, address(this));
            state.aeroAmount = aeroToken.balanceOf(address(this)) - balanceBefore;
        } else {
            // For non-vault positions, claim directly from gauge
            state.gauge = _getGaugeForPosition(state.token0, state.token1, state.tickSpacing);
            if (state.gauge == address(0)) {
                revert GaugeNotSet();
            }
            
            uint256 balanceBefore = aeroToken.balanceOf(address(this));
            IGauge(state.gauge).getReward(nonfungiblePositionManager.ownerOf(params.tokenId));
            state.aeroAmount = aeroToken.balanceOf(address(this)) - balanceBefore;
        }

        // Add any existing balances
        state.amount0 = positionBalances[params.tokenId][state.token0];
        state.amount1 = positionBalances[params.tokenId][state.token1];

        // Only proceed if we have AERO to compound
        if (state.aeroAmount > 0) {
            // Swap AERO to position tokens
            if (params.swapData0.length > 0) {
                uint256 aeroToSwap0 = state.aeroAmount / 2; // Split AERO 50/50 by default
                (uint256 amountIn0, uint256 amountOut0) = _routerSwap(
                    Swapper.RouterSwapParams(
                        aeroToken,
                        IERC20(state.token0),
                        aeroToSwap0,
                        params.minAmount0,
                        params.swapData0
                    )
                );
                state.amount0 += amountOut0;
                state.aeroAmount -= amountIn0;
            }
            
            if (params.swapData1.length > 0 && state.aeroAmount > 0) {
                (uint256 amountIn1, uint256 amountOut1) = _routerSwap(
                    Swapper.RouterSwapParams(
                        aeroToken,
                        IERC20(state.token1),
                        state.aeroAmount,
                        params.minAmount1,
                        params.swapData1
                    )
                );
                state.amount1 += amountOut1;
                // Note: we don't need to update state.aeroAmount since it's not used after this
            }
        }

        // Compound if we have tokens
        if (state.amount0 > 0 || state.amount1 > 0) {
            uint256 rewardX64 = totalRewardX64;
            
            // Calculate amounts to add (minus protocol fee)
            state.maxAddAmount0 = state.amount0 * Q64 / (rewardX64 + Q64);
            state.maxAddAmount1 = state.amount1 * Q64 / (rewardX64 + Q64);

            // Add liquidity
            if (state.maxAddAmount0 > 0 || state.maxAddAmount1 > 0) {
                _checkApprovals(state.token0, state.token1);

                (, state.compounded0, state.compounded1) = nonfungiblePositionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        params.tokenId,
                        state.maxAddAmount0,
                        state.maxAddAmount1,
                        0,
                        0,
                        params.deadline
                    )
                );

                // Calculate protocol fees
                state.amount0Fees = state.compounded0 * rewardX64 / Q64;
                state.amount1Fees = state.compounded1 * rewardX64 / Q64;
            }

            // Update balances
            _setBalance(params.tokenId, state.token0, state.amount0 - state.compounded0 - state.amount0Fees);
            _setBalance(params.tokenId, state.token1, state.amount1 - state.compounded1 - state.amount1Fees);

            // Add protocol fees to balance
            _increaseBalance(0, state.token0, state.amount0Fees);
            _increaseBalance(0, state.token1, state.amount1Fees);
        }

        emit AeroCompounded(
            msg.sender,
            params.tokenId,
            state.aeroAmount,
            state.compounded0,
            state.compounded1,
            state.amount0Fees,
            state.amount1Fees,
            state.token0,
            state.token1
        );
    }

    /// @notice Get gauge for a position based on its pool
    function _getGaugeForPosition(
        address token0,
        address token1,
        uint24 tickSpacing
    ) internal view returns (address) {
        address pool = aerodromeFactory.getPool(token0, token1, int24(tickSpacing));
        if (pool == address(0)) return address(0);
        
        // This would need to be tracked or retrieved from GaugeManager
        // For now, return the gauge from GaugeManager's mapping
        return gaugeManager.poolToGauge(pool);
    }
    
    /// @notice Get leftover balances for a position
    /// @dev Bot should call this before preparing swaps to account for existing balances
    /// @param tokenId Position ID to query
    /// @return amount0 Leftover amount of token0
    /// @return amount1 Leftover amount of token1
    /// @return token0 Address of token0
    /// @return token1 Address of token1
    function getLeftoverBalances(uint256 tokenId) external view returns (
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1
    ) {
        (,, token0, token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        amount0 = positionBalances[tokenId][token0];
        amount1 = positionBalances[tokenId][token1];
    }

    /// @notice Set reward percentage
    function setReward(uint64 _totalRewardX64) external onlyOwner {
        if (_totalRewardX64 > MAX_REWARD_X64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit RewardUpdated(msg.sender, _totalRewardX64);
    }

    /// @notice Withdraw leftover balance for a position (single token)
    /// @param tokenId Position ID
    /// @param token Token address to withdraw
    function withdrawBalance(uint256 tokenId, address token) external {
        address owner = _getPositionOwner(tokenId);
        if (msg.sender != owner && !operators[msg.sender]) {
            revert Unauthorized();
        }

        uint256 balance = positionBalances[tokenId][token];
        if (balance > 0) {
            _setBalance(tokenId, token, 0);
            IERC20(token).safeTransfer(owner, balance);
            emit BalanceWithdrawn(tokenId, token, owner, balance);
        }
    }
    
    /// @notice Withdraw all leftover balances for a position in one transaction
    /// @dev Convenience function for position owners to withdraw all leftovers at once
    /// @param tokenId Position ID
    function withdrawAllBalances(uint256 tokenId) external {
        address owner = _getPositionOwner(tokenId);
        if (msg.sender != owner && !operators[msg.sender]) {
            revert Unauthorized();
        }
        
        // Get position tokens
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        
        // Withdraw token0 if any balance
        uint256 balance0 = positionBalances[tokenId][token0];
        if (balance0 > 0) {
            _setBalance(tokenId, token0, 0);
            IERC20(token0).safeTransfer(owner, balance0);
            emit BalanceWithdrawn(tokenId, token0, owner, balance0);
        }
        
        // Withdraw token1 if any balance
        uint256 balance1 = positionBalances[tokenId][token1];
        if (balance1 > 0) {
            _setBalance(tokenId, token1, 0);
            IERC20(token1).safeTransfer(owner, balance1);
            emit BalanceWithdrawn(tokenId, token1, owner, balance1);
        }
    }
    
    /// @notice Get the actual owner of a position (handles vault positions)
    /// @param tokenId Position ID
    /// @return owner The actual owner of the position
    function _getPositionOwner(uint256 tokenId) internal view returns (address owner) {
        owner = nonfungiblePositionManager.ownerOf(tokenId);
        
        // Check if the owner is a vault - if so, get the actual owner from the vault
        if (vaults[owner]) {
            // Direct vault ownership
            (bool success, bytes memory data) = owner.staticcall(
                abi.encodeWithSelector(IVault.ownerOf.selector, tokenId)
            );
            if (success && data.length == 32) {
                owner = abi.decode(data, (address));
            }
        } else {
            // Check if it's a staked position (owner is a gauge)
            // Try to get the vault that controls this position through the GaugeManager
            // The GaugeManager has a public vault() getter
            try GaugeManager(address(gaugeManager)).vault() returns (IVault vaultContract) {
                address vaultAddress = address(vaultContract);
                if (vaults[vaultAddress]) {
                    (bool success, bytes memory data) = vaultAddress.staticcall(
                        abi.encodeWithSelector(IVault.ownerOf.selector, tokenId)
                    );
                    if (success && data.length == 32) {
                        owner = abi.decode(data, (address));
                    }
                }
            } catch {
                // If we can't get the vault, return the NPM owner
            }
        }
    }

    /// @notice Withdraw protocol fees
    function withdrawProtocolFees(address token, address to) external {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        
        uint256 balance = positionBalances[0][token];
        if (balance > 0) {
            _setBalance(0, token, 0);
            IERC20(token).safeTransfer(to, balance);
        }
    }

    // Internal balance management functions
    function _setBalance(uint256 tokenId, address token, uint256 amount) internal {
        if (amount > 0) {
            positionBalances[tokenId][token] = amount;
            emit BalanceAdded(tokenId, token, amount);
        } else {
            delete positionBalances[tokenId][token];
            emit BalanceRemoved(tokenId, token, 0);
        }
    }

    function _increaseBalance(uint256 tokenId, address token, uint256 amount) internal {
        positionBalances[tokenId][token] += amount;
        emit BalanceAdded(tokenId, token, amount);
    }

    function _checkApprovals(address token0, address token1) internal {
        // Check and set approvals for position manager
        uint256 allowance0 = IERC20(token0).allowance(address(this), address(nonfungiblePositionManager));
        if (allowance0 == 0) {
            IERC20(token0).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        }
        
        uint256 allowance1 = IERC20(token1).allowance(address(this), address(nonfungiblePositionManager));
        if (allowance1 == 0) {
            IERC20(token1).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        }
    }
} 