// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./external/uniswap/v3-periphery/libraries/LiquidityAmounts.sol";
import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../automators/Automator.sol";

/// @title AutoCompound
/// @notice Allows operator of AutoCompound contract (Revert controlled bot) to compound a position
/// Positions need to be approved (setApproval) for the contract and configured with configToken method
/// When position is inside Vault - transform is called
contract AutoCompound is Automator {

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
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive
    );

    constructor(INonfungiblePositionManager _npm, address _operator, address _withdrawer, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference, address _swapRouter) 
        Automator(_npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, address(0), address(0)) {
    }

    // configured tokens
    mapping (uint256 => bool) public positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint128 liquidity; // liquidity the calculations are based on
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 deadline; // for uniswap operations - operator promises fair value
        uint64 rewardX64;  // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    // state used during autocompound execution
    struct ExecuteState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        address tokenOwner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @notice Adjust token (which is in a Vault) - via transform method
     * Can only be called from configured operator account - vault must be configured as well
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeWithSelector(AutoCompound.execute.selector, params));
    }

    /**
     * @notice Adjust token directly (must be in correct state)
     * Can only be called only from configured operator account, or vault via transform
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender] && !vaults[msg.sender]) { 
            revert Unauthorized();
        }
        ExecuteState memory state;
        PositionConfig memory config = positionConfigs[params.tokenId];

        if (!positionConfigs[params.tokenId]) {
            revert NotConfigured();
        }

         AutoCompoundState memory state;

        // collect fees
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(params.tokenId, address(this), type(uint128).max, type(uint128).max)
        );

        // get position info
        (, , state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) = 
            nonfungiblePositionManager.positions(params.tokenId);

        state.tokenOwner = ownerOf[params.tokenId];

        // add previous balances from given tokens
        state.amount0 = state.amount0.add(accountBalances[state.tokenOwner][state.token0]);
        state.amount1 = state.amount1.add(accountBalances[state.tokenOwner][state.token1]);

        // only if there are balances to work with - start autocompounding process
        if (state.amount0 > 0 || state.amount1 > 0) {

            SwapParams memory swapParams = SwapParams(
                state.token0, 
                state.token1, 
                state.fee, 
                state.tickLower, 
                state.tickUpper, 
                state.amount0, 
                state.amount1, 
                block.timestamp, 
                params.rewardConversion, 
                state.tokenOwner == msg.sender, 
                params.doSwap
            );
    
            // checks oracle for fair price - swaps to position ratio (considering estimated reward) - calculates max amount to be added
            (state.amount0, state.amount1, state.priceX96, state.maxAddAmount0, state.maxAddAmount1) = 
                _swapToPriceRatio(swapParams);

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
                    state.amount0Fees = compounded0.mul(totalRewardX64).div(Q64);
                    state.amount1Fees = compounded1.mul(totalRewardX64).div(Q64);
                } else {
                    // calculate total added - derive fees
                    uint addedTotal0 = compounded0.add(compounded1.mul(Q96).div(state.priceX96));
                    if (params.rewardConversion == RewardConversion.TOKEN_0) {
                        state.amount0Fees = addedTotal0.mul(totalRewardX64).div(Q64);
                        // if there is not enough token0 to pay fee - pay all there is
                        if (state.amount0Fees > state.amount0.sub(compounded0)) {
                            state.amount0Fees = state.amount0.sub(compounded0);
                        }
                    } else {
                        state.amount1Fees = addedTotal0.mul(state.priceX96).div(Q96).mul(totalRewardX64).div(Q64);
                        // if there is not enough token1 to pay fee - pay all there is
                        if (state.amount1Fees > state.amount1.sub(compounded1)) {
                            state.amount1Fees = state.amount1.sub(compounded1);
                        }
                    }
                }
            }

            // calculate remaining tokens for owner
            _setBalance(state.tokenOwner, state.token0, state.amount0.sub(compounded0).sub(state.amount0Fees));
            _setBalance(state.tokenOwner, state.token1, state.amount1.sub(compounded1).sub(state.amount1Fees));

            // distribute fees - handle 2 cases (nft owner - no protocol reward / anyone else)
            if (state.tokenOwner == msg.sender) {
                reward0 = 0;
                reward1 = 0;
            } else {
                uint64 protocolRewardX64 = totalRewardX64 - compounderRewardX64;
                uint256 protocolFees0 = state.amount0Fees.mul(protocolRewardX64).div(totalRewardX64);
                uint256 protocolFees1 = state.amount1Fees.mul(protocolRewardX64).div(totalRewardX64);

                reward0 = state.amount0Fees.sub(protocolFees0);
                reward1 = state.amount1Fees.sub(protocolFees1);

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

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    function configToken(uint256 tokenId, address vault, bool isActive) external {
        
        _validateOwner(tokenId, vault);

        // must change config
        if (positionConfigs[tokenId].isActive == isActive) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = isActive;

        emit PositionConfigured(
            tokenId,
            isActive
        );
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
        accountBalances[account][token] = accountBalances[account][token].add(amount);
        emit BalanceAdded(account, token, amount);
    }

    function _setBalance(address account, address token, uint256 amount) internal {
        uint currentBalance = accountBalances[account][token];
        
        if (amount > currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceAdded(account, token, amount.sub(currentBalance));
        } else if (amount < currentBalance) {
            accountBalances[account][token] = amount;
            emit BalanceRemoved(account, token, currentBalance.sub(amount));
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
        accountBalances[msg.sender][token] = accountBalances[msg.sender][token].sub(amount);
        emit BalanceRemoved(msg.sender, token, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }

        // state used during swap execution
    struct SwapState {
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint256 positionAmount0;
        uint256 positionAmount1;
        int24 tick;
        int24 otherTick;
        uint160 sqrtPriceX96;
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

    // checks oracle for fair price - swaps to position ratio (considering estimated reward) - calculates max amount to be added
    function _swapToPriceRatio(SwapParams memory params) 
        internal 
        returns (uint256 amount0, uint256 amount1, uint256 priceX96, uint256 maxAddAmount0, uint256 maxAddAmount1) 
    {    
        SwapState memory state;

        amount0 = params.amount0;
        amount1 = params.amount1;
        
        // get price
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(params.token0, params.token1, params.fee));
        
        (state.sqrtPriceX96,state.tick,,,,,) = pool.slot0();

        // how many seconds are needed for TWAP protection
        uint32 tSecs = TWAPSeconds;
        if (tSecs > 0) {
            // check that price is not too far from TWAP (protect from price manipulation attacks)
            (state.otherTick, state.twapOk) = _getTWAPTick(pool, tSecs);
            if (state.twapOk) {
                _requireMaxTickDifference(state.tick, state.otherTick, maxTWAPTickDifference);
            } else {
                // if there is no valid TWAP - disable swap
                params.doSwap = false;
            }
        }
        
        priceX96 = uint256(state.sqrtPriceX96).mul(state.sqrtPriceX96).div(Q96);
        state.totalReward0 = amount0.add(amount1.mul(Q96).div(priceX96)).mul(totalRewardX64).div(Q64);

        // swap to correct proportions is requested
        if (params.doSwap) {

            // calculate ideal position amounts
            state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(params.tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(params.tickUpper);
            (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                                                                state.sqrtPriceX96, 
                                                                state.sqrtPriceX96Lower, 
                                                                state.sqrtPriceX96Upper, 
                                                                Q96); // dummy value we just need ratio

            // calculate how much of the position needs to be converted to the other token
            if (state.positionAmount0 == 0) {
                state.delta0 = amount0;
                state.sell0 = true;
            } else if (state.positionAmount1 == 0) {
                state.delta0 = amount1.mul(Q96).div(priceX96);
                state.sell0 = false;
            } else {
                state.amountRatioX96 = state.positionAmount0.mul(Q96).div(state.positionAmount1);
                state.sell0 = (state.amountRatioX96.mul(amount1) < amount0.mul(Q96));
                if (state.sell0) {
                    state.delta0 = amount0.mul(Q96).sub(state.amountRatioX96.mul(amount1)).div(state.amountRatioX96.mul(priceX96).div(Q96).add(Q96));
                } else {
                    state.delta0 = state.amountRatioX96.mul(amount1).sub(amount0.mul(Q96)).div(state.amountRatioX96.mul(priceX96).div(Q96).add(Q96));
                }
            }

            // adjust delta considering reward payment mode
            if (!params.isOwner) {
                if (params.bc == RewardConversion.TOKEN_0) {
                    state.rewardAmount0 = state.totalReward0;
                    if (state.sell0) {
                        if (state.delta0 >= state.totalReward0) {
                            state.delta0 = state.delta0.sub(state.totalReward0);
                        } else {
                            state.delta0 = state.totalReward0.sub(state.delta0);
                            state.sell0 = false;
                        }
                    } else {
                        state.delta0 = state.delta0.add(state.totalReward0);
                        if (state.delta0 > amount1.mul(Q96).div(priceX96)) {
                            state.delta0 = amount1.mul(Q96).div(priceX96);
                        }
                    }
                } else if (params.bc == RewardConversion.TOKEN_1) {
                    state.rewardAmount1 = state.totalReward0.mul(priceX96).div(Q96);
                    if (!state.sell0) {
                        if (state.delta0 >= state.totalReward0) {
                            state.delta0 = state.delta0.sub(state.totalReward0);
                        } else {
                            state.delta0 = state.totalReward0.sub(state.delta0);
                            state.sell0 = true;
                        }
                    } else {
                        state.delta0 = state.delta0.add(state.totalReward0);
                        if (state.delta0 > amount0) {
                            state.delta0 = amount0;
                        }
                    }
                }
            }

            if (state.delta0 > 0) {
                if (state.sell0) {
                    uint256 amountOut = _swap(
                                            abi.encodePacked(params.token0, params.fee, params.token1), 
                                            state.delta0, 
                                            params.deadline
                                        );
                    amount0 = amount0.sub(state.delta0);
                    amount1 = amount1.add(amountOut);
                } else {
                    state.delta1 = state.delta0.mul(priceX96).div(Q96);
                    // prevent possible rounding to 0 issue
                    if (state.delta1 > 0) {
                        uint256 amountOut = _swap(abi.encodePacked(params.token1, params.fee, params.token0), state.delta1, params.deadline);
                        amount0 = amount0.add(amountOut);
                        amount1 = amount1.sub(state.delta1);
                    }
                }
            }
        } else {
            if (!params.isOwner) {
                if (params.bc == RewardConversion.TOKEN_0) {
                    state.rewardAmount0 = state.totalReward0;
                } else if (params.bc == RewardConversion.TOKEN_1) {
                    state.rewardAmount1 = state.totalReward0.mul(priceX96).div(Q96);
                }
            }
        }
        
        // calculate max amount to add - considering fees (if token owner is calling - no fees)
        if (params.isOwner) {
            maxAddAmount0 = amount0;
            maxAddAmount1 = amount1;
        } else {
            // in case caller is not owner - max amounts to add are slightly lower than available amounts - to account for reward payments
            if (params.bc == RewardConversion.NONE) {
                maxAddAmount0 = amount0.mul(Q64).div(uint(totalRewardX64).add(Q64));
                maxAddAmount1 = amount1.mul(Q64).div(uint(totalRewardX64).add(Q64));
            } else {
                maxAddAmount0 = amount0 > state.rewardAmount0 ? amount0.sub(state.rewardAmount0) : 0;
                maxAddAmount1 = amount1 > state.rewardAmount1 ? amount1.sub(state.rewardAmount1) : 0;
            }
        }
    }

    function _swap(bytes memory swapPath, uint256 amount, uint256 deadline) internal returns (uint256 amountOut) {
        if (amount > 0) {
            amountOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams(swapPath, address(this), deadline, amount, 0)
            );
        }
    }
}