// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "v3-core/interfaces/callback/IUniswapV3FlashCallback.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../src/utils/FlashloanLiquidator.sol";
import "../../src/utils/Constants.sol";

contract MockERC20Flash is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSlipstreamFactoryFlash {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        pools[_key(tokenA, tokenB, tickSpacing)] = pool;
        pools[_key(tokenB, tokenA, tickSpacing)] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        return pools[_key(tokenA, tokenB, tickSpacing)];
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }

    function _key(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, tickSpacing));
    }
}

contract MockNpmFlash {
    struct Position {
        address token0;
        address token1;
        uint24 feeOrTickSpacing;
    }

    address public immutable factory;
    address public immutable WETH9;

    mapping(uint256 => Position) internal positionData;

    constructor(address _factory) {
        factory = _factory;
        WETH9 = address(0xBEEF);
    }

    function setPosition(uint256 tokenId, address token0, address token1, uint24 feeOrTickSpacing) external {
        positionData[tokenId] = Position({token0: token0, token1: token1, feeOrTickSpacing: feeOrTickSpacing});
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24 fee,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Position memory position = positionData[tokenId];
        return (0, address(0), position.token0, position.token1, position.feeOrTickSpacing, 0, 0, 0, 0, 0, 0, 0);
    }
}

contract MockVaultFlash {
    address public immutable asset;
    bool public liquidateCalled;
    uint256 public liquidationCost;
    uint256 public liquidationValue;

    constructor(address _asset, uint256 _liquidationCost, uint256 _liquidationValue) {
        asset = _asset;
        liquidationCost = _liquidationCost;
        liquidationValue = _liquidationValue;
    }

    function loanInfo(uint256) external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, liquidationCost, liquidationValue);
    }

    function liquidate(IVault.LiquidateParams calldata) external returns (uint256 amount0, uint256 amount1) {
        liquidateCalled = true;
        return (0, 0);
    }
}

contract MockSlipstreamFlashPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (amount0 != 0) {
            IERC20(token0).transfer(recipient, amount0);
        }
        if (amount1 != 0) {
            IERC20(token1).transfer(recipient, amount1);
        }
        IUniswapV3FlashCallback(recipient).uniswapV3FlashCallback(0, 0, data);
    }
}

contract FlashloanLiquidatorCallbackUnitTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant LIQUIDATION_COST = 1e18;

    MockERC20Flash internal asset;
    MockERC20Flash internal token1;
    MockSlipstreamFactoryFlash internal factory;
    MockNpmFlash internal npm;
    MockVaultFlash internal vault;
    MockSlipstreamFlashPool internal pool;
    FlashloanLiquidator internal liquidator;

    function setUp() external {
        asset = new MockERC20Flash("Asset", "AST");
        token1 = new MockERC20Flash("Token1", "TK1");

        factory = new MockSlipstreamFactoryFlash();
        npm = new MockNpmFlash(address(factory));
        vault = new MockVaultFlash(address(asset), LIQUIDATION_COST, LIQUIDATION_COST * 2);

        // Deliberate mismatch: fee != tickSpacing
        pool = new MockSlipstreamFlashPool(address(asset), address(token1), 3_000, 60);
        factory.setPool(address(asset), address(token1), 60, address(pool));

        npm.setPosition(TOKEN_ID, address(asset), address(token1), 60);
        asset.mint(address(pool), LIQUIDATION_COST * 10);

        liquidator = new FlashloanLiquidator(
            INonfungiblePositionManager(address(npm)),
            address(0),
            address(0xDEAD)
        );
    }

    function testLiquidateAcceptsSlipstreamFlashCallbackWhenFeeDiffersFromTickSpacing() external {
        FlashloanLiquidator.LiquidateParams memory params = FlashloanLiquidator.LiquidateParams({
            tokenId: TOKEN_ID,
            vault: IVault(address(vault)),
            flashLoanPool: IUniswapV3Pool(address(pool)),
            amount0In: 0,
            swapData0: "",
            amount1In: 0,
            swapData1: "",
            minReward: 0,
            deadline: block.timestamp + 1
        });

        liquidator.liquidate(params);

        assertTrue(vault.liquidateCalled(), "flash callback did not reach vault.liquidate");
    }

    function testLiquidateRejectsCallbackFromPoolNotInFactory() external {
        MockSlipstreamFlashPool unknownPool = new MockSlipstreamFlashPool(address(asset), address(token1), 3_000, 60);
        asset.mint(address(unknownPool), LIQUIDATION_COST * 10);

        FlashloanLiquidator.LiquidateParams memory params = FlashloanLiquidator.LiquidateParams({
            tokenId: TOKEN_ID,
            vault: IVault(address(vault)),
            flashLoanPool: IUniswapV3Pool(address(unknownPool)),
            amount0In: 0,
            swapData0: "",
            amount1In: 0,
            swapData1: "",
            minReward: 0,
            deadline: block.timestamp + 1
        });

        vm.expectRevert(Constants.Unauthorized.selector);
        liquidator.liquidate(params);
    }
}
