// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../src/interfaces/pancake/IPancakeV3SwapCallback.sol";
import "../../src/utils/Constants.sol";
import "../../src/utils/Swapper.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockNonfungiblePositionManager {
    address public immutable factory;
    address public immutable WETH9;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH9 = weth_;
    }
}

contract MockFactory {
    mapping(bytes32 => address) private pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        return tokenA < tokenB ? keccak256(abi.encode(tokenA, tokenB, fee)) : keccak256(abi.encode(tokenB, tokenA, fee));
    }
}

contract MockPool {
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    uint160 private sqrtPriceX96;
    int24 private tick;
    uint32 private feeProtocol;

    constructor(MockERC20 token0_, MockERC20 token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint32 feeProtocol_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        feeProtocol = feeProtocol_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, feeProtocol, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0Delta, int256 amount1Delta)
    {
        require(amountSpecified > 0, "amount");
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut = amountIn / 2;

        if (zeroForOne) {
            uint256 balanceBefore = token0.balanceOf(address(this));
            token1.transfer(recipient, amountOut);
            amount0Delta = int256(amountIn);
            amount1Delta = -int256(amountOut);
            IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(amount0Delta, amount1Delta, data);
            require(token0.balanceOf(address(this)) - balanceBefore == amountIn, "token0 not paid");
        } else {
            uint256 balanceBefore = token1.balanceOf(address(this));
            token0.transfer(recipient, amountOut);
            amount0Delta = -int256(amountOut);
            amount1Delta = int256(amountIn);
            IPancakeV3SwapCallback(msg.sender).pancakeV3SwapCallback(amount0Delta, amount1Delta, data);
            require(token1.balanceOf(address(this)) - balanceBefore == amountIn, "token1 not paid");
        }
    }
}

contract SwapperHarness is Swapper {
    constructor(INonfungiblePositionManager npm) Swapper(npm, address(0), address(0)) {}

    function exposedGetPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return address(_getPool(tokenA, tokenB, fee));
    }

    function exposedGetPoolSlot0(IUniswapV3Pool pool) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return _getPoolSlot0(pool);
    }

    function exposedPoolSwap(PoolSwapParams memory params)
        external
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        return _poolSwap(params);
    }
}

contract SwapperPancakeCompatibilityTest is Test {
    uint24 private constant FEE = 2500;

    MockERC20 private token0;
    MockERC20 private token1;
    MockFactory private factory;
    SwapperHarness private swapper;

    function setUp() external {
        token0 = new MockERC20("Token 0", "TK0");
        token1 = new MockERC20("Token 1", "TK1");
        factory = new MockFactory();

        MockNonfungiblePositionManager npm =
            new MockNonfungiblePositionManager(address(factory), address(new MockERC20("Wrapped ETH", "WETH")));
        swapper = new SwapperHarness(INonfungiblePositionManager(address(npm)));
    }

    function testPoolLookupUsesFactoryGetPoolForEitherTokenOrder() external {
        MockPool pool = _registerPool();

        assertEq(swapper.exposedGetPool(address(token0), address(token1), FEE), address(pool));
        assertEq(swapper.exposedGetPool(address(token1), address(token0), FEE), address(pool));
    }

    function testSlot0DecoderSupportsPancakeUint32FeeProtocol() external {
        MockPool pool = _registerPool();
        pool.setSlot0(2 ** 96, -12345, type(uint32).max);

        (uint160 sqrtPriceX96, int24 tick) = swapper.exposedGetPoolSlot0(IUniswapV3Pool(address(pool)));

        assertEq(sqrtPriceX96, 2 ** 96);
        assertEq(tick, -12345);
    }

    function testPancakeCallbackPaysDirectPoolSwap() external {
        MockPool pool = _registerPool();
        token0.mint(address(swapper), 100 ether);
        token1.mint(address(pool), 50 ether);

        (uint256 amountInDelta, uint256 amountOutDelta) = swapper.exposedPoolSwap(
            Swapper.PoolSwapParams(
                IUniswapV3Pool(address(pool)),
                IERC20(address(token0)),
                IERC20(address(token1)),
                FEE,
                true,
                100 ether,
                50 ether
            )
        );

        assertEq(amountInDelta, 100 ether);
        assertEq(amountOutDelta, 50 ether);
        assertEq(token0.balanceOf(address(pool)), 100 ether);
        assertEq(token1.balanceOf(address(swapper)), 50 ether);
    }

    function testPancakeCallbackRejectsUnauthorizedCaller() external {
        _registerPool();

        vm.expectRevert(Constants.Unauthorized.selector);
        swapper.pancakeV3SwapCallback(1, 0, abi.encode(address(token0), address(token1), FEE));
    }

    function _registerPool() private returns (MockPool pool) {
        pool = new MockPool(token0, token1);
        factory.setPool(address(token0), address(token1), FEE, address(pool));
    }
}
