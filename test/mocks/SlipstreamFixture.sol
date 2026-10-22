// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/SqrtPriceMath.sol";

/// @dev ABI of the pinned upstream Slipstream NonfungiblePositionManager (fixtures/upstream-gauge) where it differs
/// from Uniswap v3: mint takes a tickSpacing and an optional pool price, positions() reports the tickSpacing.
interface ISlipstreamPositionManager is IERC721 {
    struct MintParams {
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

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function refundETH() external payable;
}

/// @dev Factory double for the pinned upstream position manager bytecode. Pools are EIP-1167 clones of
/// `poolImplementation`, deployed with CREATE2 and the upstream salt, so the position manager's
/// `PoolAddress.computeAddress(factory, key)` resolves to them and its mint-callback validation passes.
/// `getPool(address,address,int24)` serves Swapper._getPool.
contract SlipstreamFactoryFixture {
    address public immutable poolImplementation;
    mapping(bytes32 => address) internal pools;

    constructor() {
        poolImplementation = address(new SlipstreamPoolFixture());
    }

    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encode(token0, token1, tickSpacing));
        pool = Clones.cloneDeterministic(poolImplementation, salt);
        SlipstreamPoolFixture(pool).initialize(token0, token1, tickSpacing, sqrtPriceX96);
        pools[salt] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[keccak256(abi.encode(token0, token1, tickSpacing))];
    }
}

/// @dev Minimal CL pool behind the upstream position manager, with a fixed price: mint pulls the token amounts of
/// the requested liquidity through the mint callback (rounded up like core), burn returns the amounts of the burned
/// liquidity (rounded down), collect pays what the position manager accounted for, and positions() reports the
/// pool-wide fee growth that `accrueFeeGrowth` advances (fund the pool with the fee tokens first). No swaps.
/// State lives in the clone, so everything is set through `initialize`, not a constructor.
contract SlipstreamPoolFixture {
    using SafeERC20 for IERC20;

    address public factory;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public tick;
    int24 public observedTick;
    address public gauge;
    uint256 public feeGrowthInside0X128;
    uint256 public feeGrowthInside1X128;
    mapping(bytes32 => uint128) public liquidityOf;

    function initialize(address _token0, address _token1, int24 _tickSpacing, uint160 _sqrtPriceX96) external {
        require(factory == address(0), "initialized");
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        sqrtPriceX96 = _sqrtPriceX96;
        tick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);
        observedTick = tick;
    }

    // --- test controls ---

    function setGauge(address _gauge) external {
        gauge = _gauge;
    }

    function setObservedTick(int24 _observedTick) external {
        observedTick = _observedTick;
    }

    /// @dev Advances the fee growth every position of this pool sees.
    function accrueFeeGrowth(uint256 delta0X128, uint256 delta1X128) external {
        feeGrowthInside0X128 += delta0X128;
        feeGrowthInside1X128 += delta1X128;
    }

    function positionKey(address owner, int24 tickLower, int24 tickUpper) external pure returns (bytes32) {
        return _key(owner, tickLower, tickUpper);
    }

    // --- ICLPool subset used by the position manager, Swapper and the automators ---

    function fee() external view returns (uint24) {
        return uint24(tickSpacing);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, tick, 0, 1, 1, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            // a constant observedTick: cumulative(now - secondsAgo) = observedTick * (now - secondsAgo)
            tickCumulatives[i] = -int56(observedTick) * int56(uint56(secondsAgos[i]));
        }
    }

    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (liquidityOf[key], feeGrowthInside0X128, feeGrowthInside1X128, 0, 0);
    }

    function getFeeGrowthInside(int24, int24) external view returns (uint256, uint256) {
        return (feeGrowthInside0X128, feeGrowthInside1X128);
    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount != 0, "L");
        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, amount, true);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        require(balance0Before + amount0 <= IERC20(token0).balanceOf(address(this)), "M0");
        require(balance1Before + amount1 <= IERC20(token1).balanceOf(address(this)), "M1");
        liquidityOf[_key(recipient, tickLower, tickUpper)] += amount;
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 key = _key(msg.sender, tickLower, tickUpper);
        uint128 liquidity = liquidityOf[key];
        require(liquidity != 0 && liquidity >= amount, "NP");
        if (amount != 0) {
            (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, amount, false);
            liquidityOf[key] = liquidity - amount;
        }
    }

    /// @dev Pays the requested amounts: the position manager only requests what it accounted for (burned liquidity
    /// and fee growth), and the pool holds the minted amounts plus the fee tokens the test transferred in.
    function collect(address recipient, int24, int24, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested;
        amount1 = amount1Requested;
        if (amount0 != 0) {
            IERC20(token0).safeTransfer(recipient, amount0);
        }
        if (amount1 != 0) {
            IERC20(token1).safeTransfer(recipient, amount1);
        }
    }

    function _amountsForLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        require(tickLower < tickUpper, "TLU");
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, roundUp);
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, roundUp);
        }
    }

    function _key(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }
}
