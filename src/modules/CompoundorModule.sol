// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import 'v3-core/interfaces/callback/IUniswapV3SwapCallback.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "../SwapAndAddLogic.sol";

/// @title CompoundorModule
/// @notice Adds auto-compounding capability (improved logic from old compoundor)
contract CompoundorModule is Module, ReentrancyGuard, Multicall, IUniswapV3SwapCallback {

    using OZSafeCast for uint256;

    error NotConfigured();

    // config changes
    event RewardUpdated(address account, uint64 totalRewardX64, uint64 compounderRewardX64);
    event TWAPConfigUpdated(address account, uint32 maxTWAPTickDifference, uint32 TWAPSeconds);

    // balance movements
    event BalanceAdded(address account, address token, uint256 amount);
    event BalanceRemoved(address account, address token, uint256 amount);
    event BalanceWithdrawn(address account, address token, address to, uint256 amount);

    // position configuration event
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive
    );

    // autocompound event
    event AutoCompounded(
        address account,
        uint256 tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );

    // max reward
    uint64 constant public MAX_REWARD_X64 = uint64(Q64 / 50); // 2%

    // changable config values
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%
    uint64 public compounderRewardX64 = MAX_REWARD_X64 / 2; // 1%
    uint16 public maxTWAPTickDifference = 100; // 1%
    uint32 public TWAPSeconds = 60;

    // balances
    mapping(address => mapping(address => uint256)) public accountBalances;
    
    struct PositionConfig {
        bool isActive;
    }
    mapping (uint256 => PositionConfig) positionConfigs;

    bool public immutable override needsCheckOnCollect = false;

    constructor(INonfungiblePositionManager _npm) Module(_npm) {
    }

    /**
     * @notice Management method to lower reward or change ratio between total and compounder reward (onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     * @param _compounderRewardX64 new compounder reward
     */
    function setReward(uint64 _totalRewardX64, uint64 _compounderRewardX64) external onlyOwner {
        require(_totalRewardX64 <= totalRewardX64, ">totalRewardX64");
        require(_compounderRewardX64 <= _totalRewardX64, "compounderRewardX64>totalRewardX64");
        totalRewardX64 = _totalRewardX64;
        compounderRewardX64 = _compounderRewardX64;
        emit RewardUpdated(msg.sender, _totalRewardX64, _compounderRewardX64);
    }

    /**
     * @notice Management method to change the max tick difference from twap to allow swaps (onlyOwner)
     * @param _maxTWAPTickDifference new max tick difference
     */
    function setTWAPConfig(uint16 _maxTWAPTickDifference, uint32 _TWAPSeconds) external onlyOwner {
        maxTWAPTickDifference = _maxTWAPTickDifference;
        TWAPSeconds = _TWAPSeconds;
        emit TWAPConfigUpdated(msg.sender, _maxTWAPTickDifference, _TWAPSeconds);
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        uint160 sqrtPriceX96;
        address sender;
        address tokenOwner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        IUniswapV3Pool pool;
        bytes returnData;
        uint256 reward0;
        uint256 reward1;
        uint256 compounded0;
        uint256 compounded1;
    }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;

        // should token be withdrawn to compounder immediately
        bool withdrawReward;

        // token swap direction
        bool doSwap;
    }

    /**
     * @notice Autocompounds for a given NFT (anyone can call this and gets a percentage of the fees)
     * @param params Autocompound specific parameters (tokenId, ...)
     * @return reward0 Amount of token0 caller recieves
     * @return reward1 Amount of token1 caller recieves
     * @return compounded0 Amount of token0 that was compounded
     * @return compounded1 Amount of token1 that was compounded
     */
    function autoCompound(AutoCompoundParams memory params) external nonReentrant returns (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1) 
    {
        PositionConfig storage config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }

        (address owner, ) = _getOwners(params.tokenId);

        // collects ONLY fees - NO liquidity
        (,,bytes memory callbackReturnData) = _decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(params.tokenId, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this), abi.encode(msg.sender, owner, params)));

        // handle return values - from callback return data
        (reward0, reward1, compounded0, compounded1) = abi.decode(callbackReturnData, (uint256, uint256, uint256, uint256));        
    }

    // callback function which is called directly after fees are available - but before checking other modules (e.g. to be able to compound and LATER check collateral)
    function decreaseLiquidityAndCollectCallback(uint256 /*tokenId*/, uint256 amount0, uint256 amount1, bytes memory data) override onlyHolderOrSelf external returns (bytes memory returnData) { 
        
        // local vars
        AutoCompoundState memory state;    
        AutoCompoundParams memory params;

        (state.sender, state.tokenOwner, params) = abi.decode(data, (address, address, AutoCompoundParams));    

        // get position info
        (, , state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) = nonfungiblePositionManager.positions(params.tokenId);

        // add previous balances from given tokens
        amount0 += accountBalances[state.tokenOwner][state.token0];
        amount1 += accountBalances[state.tokenOwner][state.token1];

        // only if there are balances to work with - start autocompounding process
        if (amount0 > 0 || amount1 > 0) {

            state.pool = _getPool(state.token0, state.token1, state.fee);

            // check oracle when price is needed during compounding
            if (params.doSwap) {

                // checks oracle - reverts if not enough data available or if price is to far away from TWAP
                (,, state.sqrtPriceX96, state.priceX96) = _validateSwap(false, 0, state.pool, TWAPSeconds, maxTWAPTickDifference, 0);

                (amount0, amount1) = SwapAndAddLogic._poolSwapForRange(SwapAndAddLogic.SwapParams(address(factory), state.token0, state.token1, state.fee, amount0, amount1, state.tickLower, state.tickUpper));
            }

            // in case caller is not owner - max amounts to add are slightly lower than available amounts - to account for reward payments
            if (state.tokenOwner != state.sender) {
                state.maxAddAmount0 = amount0 * Q64 / (totalRewardX64 + Q64);
                state.maxAddAmount1 = amount1 * Q64 / (totalRewardX64 + Q64);           
            } else {
                state.maxAddAmount0 = amount0;
                state.maxAddAmount1 = amount1;
            }

            // deposit liquidity into tokenId
            if (state.maxAddAmount0 > 0 || state.maxAddAmount1 > 0) {

                (, state.compounded0, state.compounded1) = nonfungiblePositionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        params.tokenId,
                        state.maxAddAmount0,
                        state.maxAddAmount1,
                        0,
                        0,
                        block.timestamp
                    )
                );

                // fees are always calculated based on added amount
                // only calculate them when not tokenOwner
                if (state.tokenOwner != state.sender) {
                    state.amount0Fees = state.compounded0 * totalRewardX64 / Q64;
                    state.amount1Fees = state.compounded1 * totalRewardX64 / Q64;
                }
            }

            // calculate remaining tokens for owner
            _setBalance(state.tokenOwner, state.token0, amount0 - state.compounded0 - state.amount0Fees);
            _setBalance(state.tokenOwner, state.token1, amount1 - state.compounded1 - state.amount1Fees);

            // distribute fees - only needed when not nft owner
            if (state.tokenOwner != state.sender) {
                uint64 protocolRewardX64 = totalRewardX64 - compounderRewardX64;
                uint256 protocolFees0 = state.amount0Fees * protocolRewardX64 / totalRewardX64;
                uint256 protocolFees1 = state.amount1Fees * protocolRewardX64 / totalRewardX64;

                state.reward0 = state.amount0Fees - protocolFees0;
                state.reward1 = state.amount1Fees - protocolFees1;

                _increaseBalance(state.sender, state.token0, state.reward0);
                _increaseBalance(state.sender, state.token1, state.reward1);
                _increaseBalance(owner(), state.token0, protocolFees0);
                _increaseBalance(owner(), state.token1, protocolFees1);
            }
        }

        if (params.withdrawReward) {
            _withdrawFullBalances(state.token0, state.token1, state.sender);
        }

        emit AutoCompounded(state.sender, params.tokenId, state.compounded0, state.compounded1, state.reward0, state.reward1, state.token0, state.token1);

        returnData = abi.encode(state.reward0, state.reward1, state.compounded0, state.compounded1);
    }

    /**
     * @notice Withdraws token balance for a address and token
     * @param token Address of token to withdraw
     * @param to Address to send to
     * @param amount amount to withdraw (if 0 - all available is withdrawn)
     */
    function withdrawBalance(address token, address to, uint256 amount) external nonReentrant {
        uint256 balance = accountBalances[msg.sender][token];
        if (amount == 0 || amount > balance) {
            amount = balance;
        }
        _withdrawBalanceInternal(token, to, balance, amount);
    }

    function _increaseBalance(address account, address token, uint256 amount) internal {
        accountBalances[account][token] += amount;
        emit BalanceAdded(account, token, amount);
    }

    function _setBalance(address account, address token, uint256 amount) internal {
        uint256 currentBalance = accountBalances[account][token];
        
        if (amount > currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceAdded(account, token, amount - currentBalance);
        } else if (amount < currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceRemoved(account, token, currentBalance - amount);
        }
    }

    function _withdrawFullBalances(address token0, address token1, address to) internal {
        uint256 balance0 = accountBalances[msg.sender][token0];
        if (balance0 > 0) {
            _withdrawBalanceInternal(token0, to, balance0, balance0);
        }
        uint256 balance1 = accountBalances[msg.sender][token1];
        if (balance1 > 0) {
            _withdrawBalanceInternal(token1, to, balance1, balance1);
        }
    }

    function _withdrawBalanceInternal(address token, address to, uint256 balance, uint256 amount) internal {
        require(amount <= balance, "amount>balance");
        accountBalances[msg.sender][token] -= amount;
        emit BalanceRemoved(msg.sender, token, amount);
        _transferToken(to, IERC20(token), amount, true);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }

    function _checkApprovals(IERC20 token0, IERC20 token1) internal {
        // approve tokens once if not yet approved - gas optimization
        uint256 allowance0 = token0.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance0 == 0) {
            SafeERC20.safeApprove(token0, address(nonfungiblePositionManager), type(uint256).max);
        }
        uint256 allowance1 = token1.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance1 == 0) {
            SafeERC20.safeApprove(token1, address(nonfungiblePositionManager), type(uint256).max);
        }
    }

    // function to configure module for position which is not in holder
    function addTokenDirect(uint256 tokenId, bool active) external {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner == address(holder) || owner != msg.sender) {
            revert Unauthorized();
        }
        positionConfigs[tokenId] = PositionConfig(active);
        emit PositionConfigured(tokenId, active);
    }

    // IModule needed functions
    function addToken(uint256 tokenId, address, bytes calldata) override onlyHolder external { 
        (,,address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        _checkApprovals(IERC20(token0), IERC20(token1));
        positionConfigs[tokenId] = PositionConfig(true);
        emit PositionConfigured(tokenId, true);
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
         delete positionConfigs[tokenId];
         emit PositionConfigured(tokenId, false);
    }

    function getConfig(uint256 tokenId) override external view returns (bytes memory config) {
        return abi.encode(positionConfigs[tokenId]);
    }

    // swap callback function where amount for swap is payed - @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        SwapAndAddLogic._uniswapV3SwapCallback(address(factory), amount0Delta, amount1Delta, data);
    }
}