// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";
import "./ICompoundorModule.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";

import "v3-periphery/interfaces/ISwapRouter.sol";
import "v3-periphery/libraries/LiquidityAmounts.sol";

contract CompoundorModule is Module, ICompoundorModule, ReentrancyGuard, Multicall {

    // max reward
    uint64 constant public MAX_REWARD_X64 = uint64(Q64 / 50); // 2%

    // changable config values
    uint64 public override totalRewardX64 = MAX_REWARD_X64; // 2%
    uint64 public override compounderRewardX64 = MAX_REWARD_X64 / 2; // 1%
    uint32 public override maxTWAPTickDifference = 100; // 1%
    uint32 public override TWAPSeconds = 60;
    uint16 public override maxSwapDifferenceX16 = uint16(Q16 / 100); //1%

    // balances
    mapping(address => mapping(address => uint256)) public override accountBalances;

    constructor(NFTHolder _holder, address _swapRouter) Module(_holder, _swapRouter) {
    }

    /**
     * @notice Management method to lower reward or change ratio between total and compounder reward (onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     * @param _compounderRewardX64 new compounder reward
     */
    function setReward(uint64 _totalRewardX64, uint64 _compounderRewardX64) external override onlyOwner {
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
    function setTWAPConfig(uint32 _maxTWAPTickDifference, uint32 _TWAPSeconds) external override onlyOwner {
        maxTWAPTickDifference = _maxTWAPTickDifference;
        TWAPSeconds = _TWAPSeconds;
        emit TWAPConfigUpdated(msg.sender, _maxTWAPTickDifference, _TWAPSeconds);
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 amountOutMin;
        uint256 priceX96;
        address tokenOwner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @notice Autocompounds for a given NFT (anyone can call this and gets a percentage of the fees)
     * @param params Autocompound specific parameters (tokenId, ...)
     * @return reward0 Amount of token0 caller recieves
     * @return reward1 Amount of token1 caller recieves
     * @return compounded0 Amount of token0 that was compounded
     * @return compounded1 Amount of token1 that was compounded
     */
    function autoCompound(AutoCompoundParams memory params) 
        override 
        external 
        nonReentrant 
        returns (uint256 reward0, uint256 reward1, uint256 compounded0, uint256 compounded1)
    {
        AutoCompoundState memory state;

        state.tokenOwner = holder.tokenOwners(params.tokenId);

        require(state.tokenOwner != address(0), "!found");

        // collect fees
        (state.amount0, state.amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        // get position info
        (, , state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) = nonfungiblePositionManager.positions(params.tokenId);

        // add previous balances from given tokens
        state.amount0 += accountBalances[state.tokenOwner][state.token0];
        state.amount1 += accountBalances[state.tokenOwner][state.token1];

        // only if there are balances to work with - start autocompounding process
        if (state.amount0 > 0 || state.amount1 > 0) {

            // if swap is configured - execute it
            if (params.swapAmount > 0) {
                IUniswapV3Pool pool = _getPool(state.token0, state.token1, state.fee);
                (state.amountOutMin, state.priceX96) = _validateSwap(params.swap0For1, params.swapAmount, pool, TWAPSeconds, maxTWAPTickDifference, maxSwapDifferenceX16);
                (uint amountInDelta, uint256 amountOutDelta) = _swap(params.swap0For1 ? IERC20(state.token0) : IERC20(state.token1), params.swap0For1 ? IERC20(state.token1) : IERC20(state.token0), params.swapAmount, state.amountOutMin, params.swapData);
                state.amount0 = params.swap0For1 ? state.amount0 - amountInDelta : state.amount0 + amountOutDelta;
                state.amount1 = params.swap0For1 ? state.amount1 + amountOutDelta : state.amount1 - amountInDelta;
            }

            // calculate max amount to add - considering fees (if token owner is calling - no fees)
            if (state.tokenOwner == msg.sender) {
                state.maxAddAmount0 = state.amount0;
                state.maxAddAmount1 = state.amount1;
            } else {
                // in case caller is not owner - max amounts to add are slightly lower than available amounts - to account for (potential) reward payments
                if (params.rewardConversion == RewardConversion.NONE) {
                    state.maxAddAmount0 = state.amount0 * Q64 / (totalRewardX64 + Q64);
                    state.maxAddAmount1 = state.amount1 * Q64 / (totalRewardX64 + Q64);
                } else {
                    // if not loaded previously
                    if (state.priceX96 == 0) {
                        state.priceX96 = _getPoolPrice(state.token0, state.token1, state.fee);
                    }

                    if (params.rewardConversion == RewardConversion.TOKEN_0) {
                        state.maxAddAmount0 = (state.amount0 + state.amount1 * Q96 / state.priceX96) * Q64 / (totalRewardX64 + Q64);
                        state.maxAddAmount1 = state.amount1;
                    } else {
                        state.maxAddAmount0 = state.amount0;
                        state.maxAddAmount1 = (state.amount1 + state.amount0 * state.priceX96 / Q96) * Q64 / (totalRewardX64 + Q64);
                    }
                }
            }
 
            // deposit liquidity into tokenId
            if (state.maxAddAmount0 > 0 || state.maxAddAmount1 > 0) {
                (, compounded0, compounded1) = nonfungiblePositionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        params.tokenId,
                        state.maxAddAmount0,
                        state.maxAddAmount1,
                        0,
                        0,
                        block.timestamp
                    )
                );
            }

            // fees are always calculated based on added amount
            // only calculate them when not tokenOwner
            if (state.tokenOwner != msg.sender) {
                if (params.rewardConversion == RewardConversion.NONE) {
                    state.amount0Fees = compounded0 * totalRewardX64 / Q64;
                    state.amount1Fees = compounded1 * totalRewardX64 / Q64;
                } else {
                    // calculate total added - derive fees
                    uint addedTotal0 = compounded0 + compounded1 * Q96 / state.priceX96;
                    if (params.rewardConversion == RewardConversion.TOKEN_0) {
                        state.amount0Fees = addedTotal0 * totalRewardX64 / Q64;
                        // if there is not enough token0 to pay fee - pay all there is
                        if (state.amount0Fees > state.amount0 - compounded0) {
                            state.amount0Fees = state.amount0 - compounded0;
                        }
                    } else {
                        state.amount1Fees = (addedTotal0 * state.priceX96 / Q96) * totalRewardX64 / Q64;
                        // if there is not enough token1 to pay fee - pay all there is
                        if (state.amount1Fees > state.amount1 - compounded1) {
                            state.amount1Fees = state.amount1 - compounded1;
                        }
                    }
                }
            }

            // calculate remaining tokens for owner
            _setBalance(state.tokenOwner, state.token0, state.amount0 - compounded0 - state.amount0Fees);
            _setBalance(state.tokenOwner, state.token1, state.amount1 - compounded1 - state.amount1Fees);

            // distribute fees - (if nft owner - no protocol reward / anyone else)
            if (state.tokenOwner != msg.sender) {
                uint64 protocolRewardX64 = totalRewardX64 - compounderRewardX64;
                uint256 protocolFees0 = state.amount0Fees * protocolRewardX64 / totalRewardX64;
                uint256 protocolFees1 = state.amount1Fees * protocolRewardX64 / totalRewardX64;

                reward0 = state.amount0Fees - protocolFees0;
                reward1 = state.amount1Fees - protocolFees1;

                _increaseBalance(msg.sender, state.token0, reward0);
                _increaseBalance(msg.sender, state.token1, reward1);
                _increaseBalance(owner(), state.token0, protocolFees0);
                _increaseBalance(owner(), state.token1, protocolFees1);
            }
        }

        if (params.withdrawReward) {
            _withdrawFullBalances(state.token0, state.token1, msg.sender);
        }

        emit AutoCompounded(msg.sender, params.tokenId, compounded0, compounded1, reward0, reward1, state.token0, state.token1);
    }

    /**
     * @notice Withdraws token balance for a address and token
     * @param token Address of token to withdraw
     * @param to Address to send to
     * @param amount amount to withdraw
     */
    function withdrawBalance(address token, address to, uint256 amount) external override nonReentrant {
        require(amount > 0, "amount==0");
        uint256 balance = accountBalances[msg.sender][token];
        _withdrawBalanceInternal(token, to, balance, amount);
    }

    function _increaseBalance(address account, address token, uint256 amount) internal {
        accountBalances[account][token] += amount;
        emit BalanceAdded(account, token, amount);
    }

    function _setBalance(address account, address token, uint256 amount) internal {
        uint currentBalance = accountBalances[account][token];
        
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
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }

    function _checkApprovals(IERC20 token0, IERC20 token1) internal {
        // approve tokens once if not yet approved
        uint256 allowance0 = token0.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance0 == 0) {
            SafeERC20.safeApprove(token0, address(nonfungiblePositionManager), type(uint256).max);
        }
        uint256 allowance1 = token1.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance1 == 0) {
            SafeERC20.safeApprove(token1, address(nonfungiblePositionManager), type(uint256).max);
        }
    }

    // IModule required functions
    function addToken(uint256 tokenId, address owner, bytes calldata data) override external  { }

    function withdrawToken(uint256 tokenId, address owner) override external { }

    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
}