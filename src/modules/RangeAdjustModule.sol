// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./OperatorModule.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

/// @title RangeAdjustModule
/// @notice Allows operator of RangeAdjustModule contract (Revert controlled bot) to change range for configured positions
/// Positions need to be approved for all NFTs for the contract and configured with setConfig method
contract RangeAdjustModule is OperatorModule {

    // user events
    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    event PositionConfigured(
        uint256 indexed tokenId,
        int32 lowerTickLimit,
        int32 upperTickLimit,
        int32 lowerTickDelta,
        int32 upperTickDelta,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64
    );

    // errors 
    error WrongContract();
    error AdjustStateError();
    error NotConfigured();
    error NotReady();
    error SameRange();
    error NotSupportedFeeTier();

    uint64 immutable public protocolRewardX64 = uint64(Q64 / 200); // 0.5%

    bool public immutable override needsCheckOnCollect = false;

    constructor(INonfungiblePositionManager _npm, address _swapRouter, address _operator, uint32 _TWAPSeconds, uint16 _maxTWAPTickDifference) OperatorModule(_npm, _swapRouter, _operator, _TWAPSeconds, _maxTWAPTickDifference) {
    }

    // defines when and how a position can be changed by operator
    // when a position is adjusted config for the position is cleared and copied to the newly created position
    struct PositionConfig {
        // needs more than int24 because it can be [-type(uint24).max,type(uint24).max]
        int32 lowerTickLimit; // if negative also in-range positions may be adjusted
        int32 upperTickLimit; // if negative also in-range positions may be adjusted
        int32 lowerTickDelta; // this amount is added to current tick (floored to tickspacing) to define lowerTick of new position
        int32 upperTickDelta; // this amount is added to current tick (floored to tickspacing) to define upperTick of new position
        uint64 token0SlippageX64; // max price difference from current pool price for swap / Q64 for token0
        uint64 token1SlippageX64; // max price difference from current pool price for swap / Q64 for token1
    }

    // configured tokens
    mapping (uint256 => PositionConfig) public positionConfigs;

    /**
     * @notice Withdraws token balance for a address and token
     * @param token Address of token to withdraw
     * @param to Address to send t
     */
    function withdrawBalance(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _transferToken(to, IERC20(token), balance, true);
        }
    }

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 deadline; // for uniswap operations - operator promises fair value
    }

    struct ExecuteState {
        address owner;
        address currentOwner;
        IUniswapV3Pool pool;
        uint160 sqrtPriceX96;
        uint256 priceX96;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int24 currentTick;
        uint256 amount0;
        uint256 amount1;
        uint256 protocolReward0;
        uint256 protocolReward1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        uint256 value;
        uint256 balance0;
        uint256 balance1;
        uint256 newTokenId;
        int24 twapTick;
    }

    /**
     * @notice Adjust token (must be in correct state)
     * Can be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams memory params) external {

        if (msg.sender != operator) {
            revert Unauthorized();
        }

        PositionConfig storage config = positionConfigs[params.tokenId];
        if (config.lowerTickDelta == config.upperTickDelta) {
            revert NotConfigured();
        }

        ExecuteState memory state;

        // get position info
        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity, , , , ) =  nonfungiblePositionManager.positions(params.tokenId);

        // get pool info
        state.pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.currentTick, , , , , ) = state.pool.slot0();


        if (state.currentTick < state.tickLower - config.lowerTickLimit || state.currentTick >= state.tickUpper + config.upperTickLimit) {

            // decrease full liquidity for given position - and return fees as well
            (state.amount0, state.amount1, ) = _decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(params.tokenId, state.liquidity, 0, 0, type(uint128).max, type(uint128).max, params.deadline, false, address(this), ""));

            // TODO use callback style handling

            // check oracle for swap
            (state.amountOutMin,,) = _validateSwap(params.swap0To1, params.amountIn, state.pool, TWAPSeconds, maxTWAPTickDifference, params.swap0To1 ? config.token0SlippageX64 : config.token1SlippageX64);

            (state.amountInDelta, state.amountOutDelta) = _swap(swapRouter, params.swap0To1 ? IERC20(state.token0) : IERC20(state.token1), params.swap0To1 ? IERC20(state.token1) : IERC20(state.token0), params.amountIn, state.amountOutMin, params.swapData);

            state.amount0 = params.swap0To1 ? state.amount0 - state.amountInDelta : state.amount0 + state.amountOutDelta;
            state.amount1 = params.swap0To1 ? state.amount1 + state.amountOutDelta : state.amount1 - state.amountInDelta;

            // protocol reward is removed from both token amounts and kept in contract for later retrieval
            state.protocolReward0 = state.amount0 * protocolRewardX64 / Q64;
            state.protocolReward1 = state.amount1 * protocolRewardX64 / Q64;

            // approve npm 
            SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), state.amount0 - state.protocolReward0);
            SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), state.amount1 - state.protocolReward1);

            int24 tickSpacing = _getTickSpacing(state.fee);
            int24 baseTick = state.currentTick - (((state.currentTick % tickSpacing) + tickSpacing) % tickSpacing);

            // check if new range same as old range
            if (baseTick + config.lowerTickDelta == state.tickLower && baseTick + config.upperTickDelta == state.tickUpper) {
                revert SameRange();
            }

            INonfungiblePositionManager.MintParams memory mintParams = 
                INonfungiblePositionManager.MintParams(
                    address(state.token0), 
                    address(state.token1), 
                    state.fee, 
                    OZSafeCast.toInt24(baseTick + config.lowerTickDelta), // reverts if out of valid range
                    OZSafeCast.toInt24(baseTick + config.upperTickDelta), // reverts if out of valid range
                    state.amount0 - state.protocolReward0,
                    state.amount1 - state.protocolReward1, 
                    0,
                    0,
                    address(this), // is sent to real recipient aftwards
                    params.deadline
                );

            // mint is done to address(this) first - its not a safemint
            (state.newTokenId,,state.balance0,state.balance1) = nonfungiblePositionManager.mint(mintParams);

            SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
            SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);
            
            (state.owner, state.currentOwner) = _getOwners(params.tokenId);

            // send it to current owner - if its holder it is added for real owner
            // send previous token id to reciever in data (so holder can assign and copy config)
            nonfungiblePositionManager.safeTransferFrom(address(this), state.currentOwner, state.newTokenId, abi.encode(params.tokenId));

            // send leftover to owner
            if (state.amount0 - state.protocolReward0 - state.balance0 > 0) {
                _transferToken(state.owner, IERC20(state.token0), state.amount0 - state.protocolReward0 - state.balance0, true);
            }
            if (state.amount1 - state.protocolReward1 - state.balance1 > 0) {
                _transferToken(state.owner, IERC20(state.token1), state.amount1 - state.protocolReward1 - state.balance1, true);
            }

            // copy token config for new token
            if (state.currentOwner != address(holder)) {
                positionConfigs[state.newTokenId] = config;
                emit PositionConfigured(
                    state.newTokenId,
                    config.lowerTickLimit,
                    config.upperTickLimit,
                    config.lowerTickDelta,
                    config.upperTickDelta,
                    config.token0SlippageX64,
                    config.token1SlippageX64
                );

                // delete config for old position
                delete positionConfigs[params.tokenId];
                emit PositionConfigured(params.tokenId, 0, 0, 0, 0, 0, 0);
            }

            emit RangeChanged(params.tokenId, state.newTokenId);
        } else {
            revert NotReady();
        }
    }

    // function to configure module for position which is not in holder
    function addTokenDirect(uint256 tokenId, PositionConfig memory config) external {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner == address(holder) || owner != msg.sender) {
            revert Unauthorized();
        }
        _addToken(tokenId, config);
    }

    // function to set config for token - can be only called from holder
    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        PositionConfig memory config = abi.decode(data, (PositionConfig));
        _addToken(tokenId, config);
    }

    function _addToken(uint tokenId, PositionConfig memory config) internal {
        (,,address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(tokenId);

         // lower tick must be always below or equal to upper tick - if they are equal - range adjustment is deactivated
        if (config.lowerTickDelta > config.upperTickDelta) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.token0SlippageX64,
            config.token1SlippageX64
        );
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
         delete positionConfigs[tokenId];

         emit PositionConfigured(
            tokenId,
            0,
            0,
            0,
            0,
            0,
            0
         );
    }

    // get tick spacing for fee tier (cached when possible)
    function _getTickSpacing(uint24 fee) internal view returns (int24) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 500) {
            return 10;
        } else {
            int24 spacing = factory.feeAmountTickSpacing(fee);
            if (spacing <= 0) {
                revert NotSupportedFeeTier();
            }
            return spacing;
        }
    }

    function getConfig(uint256 tokenId) override external view returns (bytes memory config) {
        return abi.encode(positionConfigs[tokenId]);
    }
}