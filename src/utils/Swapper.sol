// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";

import "../../lib/IWETH9.sol";
import "../../lib/IUniversalRouter.sol";
import "../utils/Constants.sol";

// base functionality to do swaps with different routing protocols
abstract contract Swapper is IUniswapV3SwapCallback, Constants {
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    // Aerodrome Slipstream NPM mint selector:
    // mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint160))
    bytes4 private constant AERODROME_MINT_SELECTOR = 0xb5007d1f;

    /// @notice Wrapped native token address
    IWETH9 public immutable weth;

    address public immutable factory;

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Uniswap Universal Router
    address public immutable universalRouter;

    /// @notice 0x Protocol AllowanceHolder contract
    address public immutable zeroxAllowanceHolder;

    /// @notice Constructor
    /// @param _nonfungiblePositionManager Uniswap v3 position manager
    /// @param _universalRouter Uniswap Universal Router
    /// @param _zeroxAllowanceHolder 0x Protocol AllowanceHolder contract
    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) {
        weth = IWETH9(_nonfungiblePositionManager.WETH9());
        factory = _nonfungiblePositionManager.factory();
        nonfungiblePositionManager = _nonfungiblePositionManager;
        universalRouter = _universalRouter;
        zeroxAllowanceHolder = _zeroxAllowanceHolder;
    }

    // swap data for uni - must include sweep for input token
    struct UniversalRouterData {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    struct RouterSwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns token amounts deltas after swap
    function _routerSwap(RouterSwapParams memory params)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (
            params.amountIn == 0 || params.swapData.length == 0 || address(params.tokenOut) == address(0)
                || address(params.tokenIn) == address(0)
        ) {
            return (0, 0);
        }

        uint256 balanceInBefore = params.tokenIn.balanceOf(address(this));
        uint256 balanceOutBefore = params.tokenOut.balanceOf(address(this));

        // Check if this is Universal Router data by looking at first 32 bytes
        bool isUniversalRouter;
        bytes memory swapData = params.swapData;
        address uniRouter = universalRouter;
        assembly ("memory-safe") {
            let firstWord := mload(add(swapData, 32))
            isUniversalRouter := eq(firstWord, uniRouter)
        }

        if (isUniversalRouter) {
            // Handle Universal Router case
            (, bytes memory routerData) = abi.decode(params.swapData, (address, bytes));
            UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
            SafeERC20.safeTransfer(params.tokenIn, universalRouter, params.amountIn);
            IUniversalRouter(universalRouter).execute(data.commands, data.inputs, data.deadline);
        } else {
            // For 0x v2, use raw data
            SafeERC20.safeIncreaseAllowance(params.tokenIn, zeroxAllowanceHolder, params.amountIn);
            (bool success,) = zeroxAllowanceHolder.call(params.swapData);
            if (!success) {
                revert SwapFailed();
            }
            SafeERC20.safeApprove(params.tokenIn, zeroxAllowanceHolder, 0);
        }

        amountInDelta = balanceInBefore - params.tokenIn.balanceOf(address(this));
        amountOutDelta = params.tokenOut.balanceOf(address(this)) - balanceOutBefore;

        if (amountOutDelta < params.amountOutMin) {
            revert SlippageError();
        }

        emit Swap(address(params.tokenIn), address(params.tokenOut), amountInDelta, amountOutDelta);
    }

    struct PoolSwapParams {
        IUniswapV3Pool pool;
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        bool swap0For1;
        uint256 amountIn;
        uint256 amountOutMin;
    }

    struct AerodromeMintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    // execute swap directly on specified pool
    // amounts must be available on the contract for both tokens
    function _poolSwap(PoolSwapParams memory params) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (params.amountIn != 0) {
            (int256 amount0Delta, int256 amount1Delta) = params.pool
                .swap(
                    address(this),
                    params.swap0For1,
                    int256(params.amountIn),
                    (params.swap0For1 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1),
                    abi.encode(
                        params.swap0For1 ? params.token0 : params.token1,
                        params.swap0For1 ? params.token1 : params.token0,
                        params.fee
                    )
                );
            if (params.swap0For1) {
                amountInDelta = SafeCast.toUint256(amount0Delta);
                amountOutDelta = SafeCast.toUint256(-amount1Delta);
            } else {
                amountInDelta = SafeCast.toUint256(amount1Delta);
                amountOutDelta = SafeCast.toUint256(-amount0Delta);
            }

            // amountMin slippage check
            if (amountOutDelta < params.amountOutMin) {
                revert SlippageError();
            }
        }
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    function _validateSwap(
        bool swap0For1,
        uint256 amountIn,
        IUniswapV3Pool pool,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint32 twapPeriod,
        uint16 maxTickDifference,
        uint64 maxPriceDifferenceX64
    ) internal view returns (uint256 amountOutMin) {
        if (!_hasMaxTWAPTickDifference(pool, twapPeriod, currentTick, maxTickDifference)) {
            revert TWAPCheckFailed();
        }

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), priceX96, Q160);
        } else {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), Q32, priceX96);
        }
    }

    function _hasMaxTWAPTickDifference(IUniswapV3Pool pool, uint32 twapPeriod, int24 currentTick, uint16 maxDifference)
        internal
        view
        returns (bool)
    {
        (int24 twapTick, bool twapOk) = _getTWAPTick(pool, twapPeriod);
        if (twapOk) {
            int256 res = twapTick - currentTick;
            int256 maxDifferenceInt = int256(uint256(maxDifference));
            return res >= -maxDifferenceInt && res <= maxDifferenceInt;
        } else {
            return false;
        }
    }

    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapSeconds) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = twapSeconds;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[0] - tickCumulatives[1];
            int256 twapSecondsInt = int256(uint256(twapSeconds));
            int24 tick = SafeCast.toInt24(int256(delta) / twapSecondsInt);
            if (delta < 0 && int256(delta) % twapSecondsInt != 0) tick--;
            return (tick, true);
        } catch {
            return (0, false);
        }
    }

    function _getPoolSlot0(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (bool success, bytes memory data) = address(pool).staticcall(abi.encodeWithSelector(pool.slot0.selector));
        if (!success || data.length < 64) {
            revert InvalidPool();
        }

        uint256 word0;
        uint256 word1;
        assembly ("memory-safe") {
            word0 := mload(add(data, 32))
            word1 := mload(add(data, 64))
        }

        sqrtPriceX96 = SafeCast.toUint160(word0);
        assembly ("memory-safe") {
            tick := signextend(2, word1)
        }
    }

    function _mintPosition(INonfungiblePositionManager.MintParams memory params)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        AerodromeMintParams memory aerodromeParams = AerodromeMintParams({
            token0: params.token0,
            token1: params.token1,
            tickSpacing: _toTickSpacing(params.fee),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: params.amount0Desired,
            amount1Desired: params.amount1Desired,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            recipient: params.recipient,
            deadline: params.deadline,
            sqrtPriceX96: 0
        });

        // Try Aerodrome mint first. On Uniswap this selector is missing and call reverts.
        (bool aerodromeSuccess, bytes memory aerodromeData) = address(nonfungiblePositionManager).call(
            abi.encodeWithSelector(AERODROME_MINT_SELECTOR, aerodromeParams)
        );
        if (aerodromeSuccess) {
            return abi.decode(aerodromeData, (uint256, uint128, uint256, uint256));
        }

        // Fallback to canonical Uniswap V3 mint.
        (bool uniswapSuccess, bytes memory uniswapData) =
            address(nonfungiblePositionManager).call(abi.encodeWithSelector(INonfungiblePositionManager.mint.selector, params));
        if (uniswapSuccess) {
            return abi.decode(uniswapData, (uint256, uint128, uint256, uint256));
        }

        // Bubble the most informative revert data.
        if (uniswapData.length > 0) {
            _revertWithData(uniswapData);
        }
        _revertWithData(aerodromeData);
    }

    function _revertWithData(bytes memory revertData) private pure {
        if (revertData.length == 0) {
            revert SwapFailed();
        }
        assembly ("memory-safe") {
            revert(add(revertData, 32), mload(revertData))
        }
    }

    // swap callback function where amount for swap is payed
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // check if really called from pool
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        // transfer needed amount of tokenIn
        int256 amountInDelta = amount0Delta > 0 ? amount0Delta : amount1Delta;
        SafeERC20.safeTransfer(IERC20(tokenIn), msg.sender, SafeCast.toUint256(amountInDelta));
    }

    // get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        // Aerodrome uses getPool(tokenA, tokenB, tickSpacing) and stores tickSpacing in the `fee` field of positions().
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(IAerodromeSlipstreamFactory.getPool.selector, tokenA, tokenB, _toTickSpacing(fee))
        );
        if (success && data.length >= 32) {
            address poolAddress = abi.decode(data, (address));
            if (poolAddress != address(0)) {
                return IUniswapV3Pool(poolAddress);
            }
        }

        // Uniswap v3 uses getPool(tokenA, tokenB, fee).
        (success, data) =
            factory.staticcall(abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, tokenA, tokenB, fee));
        if (success && data.length >= 32) {
            return IUniswapV3Pool(abi.decode(data, (address)));
        }

        return IUniswapV3Pool(address(0));
    }

    function _toTickSpacing(uint24 fee) internal pure returns (int24 tickSpacing) {
        assembly ("memory-safe") {
            tickSpacing := fee
        }
    }
}
