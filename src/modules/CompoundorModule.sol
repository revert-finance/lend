// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import 'v3-core/interfaces/callback/IUniswapV3SwapCallback.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

/// @title CompoundorModule
/// @notice Adds auto-compounding capability (improved logic from old compoundor)
contract CompoundorModule is Module, ReentrancyGuard, Multicall, IUniswapV3SwapCallback {

    using OZSafeCast for uint256;

    // config changes
    event RewardUpdated(address account, uint64 totalRewardX64, uint64 compounderRewardX64);
    event TWAPConfigUpdated(address account, uint32 maxTWAPTickDifference, uint32 TWAPSeconds);

    // balance movements
    event BalanceAdded(address account, address token, uint256 amount);
    event BalanceRemoved(address account, address token, uint256 amount);
    event BalanceWithdrawn(address account, address token, address to, uint256 amount);

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
    uint32 public maxTWAPTickDifference = 100; // 1%
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
    function setTWAPConfig(uint32 _maxTWAPTickDifference, uint32 _TWAPSeconds) external onlyOwner {
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

    /// @notice how reward should be converted
    enum RewardConversion { NONE, TOKEN_0, TOKEN_1 }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;
        
        // which token to convert to
        RewardConversion rewardConversion;

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
        address tokenOwner = _getOwner(params.tokenId);
        require(tokenOwner != address(0), "!found");

        // collects ONLY fees - NO liquidity
        (,,bytes memory callbackReturnData) = _decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(params.tokenId, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this), abi.encode(msg.sender, tokenOwner, params)));

        // handle return values - from callback return data
        (reward0, reward1, compounded0, compounded1) = abi.decode(callbackReturnData, (uint256, uint256, uint256, uint256));        
    }

    // callback function which is called directly after fees are available - but before checking other modules (e.g. to be able to compound and LATER check collateral)
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint256 amount0, uint256 amount1, bytes memory data) override onlyHolder(tokenId) public returns (bytes memory returnData) { 
        
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
            if (params.doSwap || params.rewardConversion != RewardConversion.NONE) {
                // checks oracle - reverts if not enough data available or if price is to far away from TWAP
                (, state.sqrtPriceX96, state.priceX96) = _validateSwap(false, 0, state.pool, TWAPSeconds, maxTWAPTickDifference, 0);
                // swap if needed
                if (params.doSwap) {
                     SwapParams memory swapParams = SwapParams(
                        state.pool,
                        state.priceX96, 
                        state.sqrtPriceX96, 
                        state.token0, 
                        state.token1, 
                        state.fee,
                        state.tickLower, 
                        state.tickUpper, 
                        amount0, 
                        amount1, 
                        block.timestamp, 
                        params.rewardConversion, 
                        state.tokenOwner == state.sender, 
                        params.doSwap
                    );

                    (amount0, amount1) = _handleSwap(swapParams);
                }
            }

            // in case caller is not owner - max amounts to add are slightly lower than available amounts - to account for reward payments
            if (state.tokenOwner != state.sender) {
                if (params.rewardConversion == RewardConversion.NONE) {
                    state.maxAddAmount0 = amount0 * Q64 / (totalRewardX64 + Q64);
                    state.maxAddAmount1 = amount1 * Q64 / (totalRewardX64 + Q64);
                } else if (params.rewardConversion == RewardConversion.TOKEN_0) {
                    uint256 rewardAmount0 = (amount0 + amount1 * Q96 / state.priceX96) * totalRewardX64 / Q64;
                    state.maxAddAmount0 = amount0 > rewardAmount0 ? amount0 - rewardAmount0 : 0;  
                    state.maxAddAmount1 = amount1;                        
                } else {
                    uint256 rewardAmount1 = (amount0 * state.priceX96 / Q96 + amount1) * totalRewardX64 / Q64;
                    state.maxAddAmount0 = amount0;
                    state.maxAddAmount1 = amount1 > rewardAmount1 ? amount1 - rewardAmount1 : 0;    
                }                    
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
                    if (params.rewardConversion == RewardConversion.NONE) {
                        state.amount0Fees = state.compounded0 * totalRewardX64 / Q64;
                        state.amount1Fees = state.compounded1 * totalRewardX64 / Q64;
                    } else {
                        // calculate total added - derive fees
                        uint256 addedTotal0 = state.compounded0 + state.compounded1 * Q96 / state.priceX96;
                        if (params.rewardConversion == RewardConversion.TOKEN_0) {
                            state.amount0Fees = addedTotal0 * totalRewardX64 / Q64;
                            // if there is not enough token0 to pay fee - pay all there is
                            if (state.amount0Fees > amount0 - state.compounded0) {
                                state.amount0Fees = amount0 - state.compounded0;
                            }
                        } else {
                            state.amount1Fees = (addedTotal0 * state.priceX96 / Q96) * totalRewardX64 / Q64;
                            // if there is not enough token1 to pay fee - pay all there is
                            if (state.amount1Fees > amount1 - state.compounded1) {
                                state.amount1Fees = amount1 - state.compounded1;
                            }
                        }
                    }
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

    struct SwapState {
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint256 positionAmount0;
        uint256 positionAmount1;
        int24 tick;
        int24 otherTick;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint256 amountRatioX96;
        uint256 delta0;
        uint256 delta1;
        bool sell0;
        bool twapOk;
        uint256 totalReward0;
    }

    struct SwapParams {
        IUniswapV3Pool pool;
        uint256 priceX96; // oracle verified price
        uint160 sqrtPriceX96; // oracle verified price - sqrt
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower; 
        int24 tickUpper; 
        uint256 amount0;
        uint256 amount1;
        uint256 deadline;
        RewardConversion bc;
        bool isOwner;
        bool doSwap;
    }

    // calculates swap amounts considering RewardConversion and executes swap - uses oracle validated price for calculations
    function _handleSwap(SwapParams memory params) internal returns (uint256 amount0, uint256 amount1) 
    {
        SwapState memory state;

        amount0 = params.amount0;
        amount1 = params.amount1;

        // total reward to be payed - converted to token0 at current price
        state.totalReward0 = (params.amount0 + params.amount1 * Q96 / params.priceX96) * totalRewardX64 / Q64;

        // calculate ideal position amounts
        state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(params.tickLower);
        state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(params.tickUpper);
        (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                                                            params.sqrtPriceX96, 
                                                            state.sqrtPriceX96Lower, 
                                                            state.sqrtPriceX96Upper, 
                                                            uint128(Q96)); // dummy value we just need ratio

        // calculate how much of the position needs to be converted to the other token
        if (state.positionAmount0 == 0) {
            state.delta0 = amount0;
            state.sell0 = true;
        } else if (state.positionAmount1 == 0) {
            state.delta0 = amount1 * Q96 / params.priceX96;
            state.sell0 = false;
        } else {
            state.amountRatioX96 = state.positionAmount0 * Q96 / state.positionAmount1;
            state.sell0 = state.amountRatioX96 * amount1 < amount0 * Q96;
            if (state.sell0) {
                state.delta0 = (amount0 * Q96 - state.amountRatioX96 * amount1) / (state.amountRatioX96 * params.priceX96 / Q96 + Q96);
            } else {
                state.delta0 = (state.amountRatioX96 * amount1 - amount0 * Q96) / (state.amountRatioX96 * params.priceX96 / Q96 + Q96);
            }
        }
      

        // adjust delta considering reward payment mode
        if (!params.isOwner) {
            if (params.bc == RewardConversion.TOKEN_0) {
                state.rewardAmount0 = state.totalReward0;
                if (state.sell0) {
                    if (state.delta0 >= state.totalReward0) {
                        state.delta0 -= state.totalReward0;
                    } else {
                        state.delta0 = state.totalReward0 - state.delta0;
                        state.sell0 = false;
                    }
                } else {
                    state.delta0 += state.totalReward0;
                    if (state.delta0 > amount1 * Q96 / params.priceX96) {
                        state.delta0 = amount1 * Q96 / params.priceX96;
                    }
                }
            } else if (params.bc == RewardConversion.TOKEN_1) {
                state.rewardAmount1 = state.totalReward0 * params.priceX96 / Q96;
                if (!state.sell0) {
                    if (state.delta0 >= state.totalReward0) {
                        state.delta0 -= state.totalReward0;
                    } else {
                        state.delta0 = state.totalReward0 - state.delta0;
                        state.sell0 = true;
                    }
                } else {
                    state.delta0 += state.totalReward0;
                    if (state.delta0 > amount0) {
                        state.delta0 = amount0;
                    }
                }
            }
        }

        if (state.delta0 > 0) {
            if (state.sell0) {
                uint256 amountOut = _poolSwap(params.pool, params.token0, params.token1, params.fee, state.sell0, state.delta0, 0);    
                amount0 -= state.delta0;
                amount1 += amountOut;                                    
            } else {
                state.delta1 = state.delta0 * params.priceX96 / Q96;
                // prevent possible rounding to 0 issue
                if (state.delta1 > 0) {
                    uint256 amountOut = _poolSwap(params.pool, params.token0, params.token1, params.fee, state.sell0, state.delta1, 0);
                    amount0 += amountOut;
                    amount1 -= state.delta1;
                }
            }
        }
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

    // IModule needed functions
    function addToken(uint256 tokenId, address, bytes calldata) override onlyHolder(tokenId) external { 
        (,,address token0, address token1, uint24 fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        _checkApprovals(IERC20(token0), IERC20(token1));
        positionConfigs[tokenId] = PositionConfig(true);
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder(tokenId) external {
         delete positionConfigs[tokenId];
    }

    // general swap function which uses given pool to swap amount available in the contract
    // returns new token amounts after swap
    function _poolSwap(IUniswapV3Pool pool, address token0, address token1, uint24 fee, bool zeroForOne, uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {
        
        (int256 amount0, int256 amount1) = pool.swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1),
                abi.encode(zeroForOne ? token0 : token1, zeroForOne ? token1 : token0, fee)
            );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        if (amountOut < minAmountOut) {
            revert SlippageError();
        }
    }

    // swap callback function where amount for swap is payed - @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {

        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // check if really called from pool
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        // transfer needed amount of tokenIn
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        SafeERC20.safeTransfer(IERC20(tokenIn), msg.sender, amountToPay);
    }
}