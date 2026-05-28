// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../../src/interfaces/pancake/IPancakeMasterChefV3.sol";

interface IPancakeV3FactoryBsc {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IPancakePositionManagerViewBsc is INonfungiblePositionManager {
    function deployer() external view returns (address);
}

interface IPancakeMasterChefV3ViewBsc is IPancakeMasterChefV3 {
    function poolLength() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
}

contract PancakeBscForkTest is Test {
    bytes32 internal constant PANCAKE_POOL_INIT_CODE_HASH =
        0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    IPancakePositionManagerViewBsc internal constant NPM =
        IPancakePositionManagerViewBsc(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364);
    IPancakeV3FactoryBsc internal constant FACTORY =
        IPancakeV3FactoryBsc(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
    IPancakeMasterChefV3ViewBsc internal constant MASTER_CHEF =
        IPancakeMasterChefV3ViewBsc(0x556B9306565093C855AEA9AE92A594704c2Cd59e);

    IUniswapV3Pool internal constant WBNB_USDT_POOL = IUniswapV3Pool(0x172fcD41E0913e95784454622d1c3724f546f849);
    IUniswapV3Pool internal constant CAKE_WBNB_POOL = IUniswapV3Pool(0x133B3D95bAD5405d14d53473671200e9342896BF);
    IUniswapV3Pool internal constant CAKE_USDT_POOL = IUniswapV3Pool(0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1);

    function setUp() external {
        vm.createSelectFork(_bscRpc());
    }

    function testBscPancakeConfigSanity() external {
        assertEq(address(NPM), MASTER_CHEF.nonfungiblePositionManager());
        assertEq(CAKE, MASTER_CHEF.CAKE());
        assertEq(NPM.factory(), address(FACTORY));
        assertGt(MASTER_CHEF.poolLength(), 0);
        assertGt(MASTER_CHEF.totalAllocPoint(), 0);

        assertEq(FACTORY.getPool(WBNB, USDT, 100), address(WBNB_USDT_POOL));
        assertEq(FACTORY.getPool(CAKE, WBNB, 2500), address(CAKE_WBNB_POOL));
        assertEq(FACTORY.getPool(CAKE, USDT, 2500), address(CAKE_USDT_POOL));
        assertEq(_computePancakePool(NPM.deployer(), WBNB, USDT, 100), address(WBNB_USDT_POOL));
        assertTrue(_computePancakePool(address(FACTORY), WBNB, USDT, 100) != address(WBNB_USDT_POOL));

        uint256 pid = MASTER_CHEF.v3PoolAddressPid(address(WBNB_USDT_POOL));
        assertGt(pid, 0);
        (, IUniswapV3Pool configuredPool, address token0, address token1, uint24 fee,,) = MASTER_CHEF.poolInfo(pid);
        assertEq(address(configuredPool), address(WBNB_USDT_POOL));
        assertEq(token0, USDT);
        assertEq(token1, WBNB);
        assertEq(fee, 100);
    }

    function _bscRpc() internal returns (string memory rpcUrl) {
        try vm.envString("BSC_RPC_URL") returns (string memory url) {
            return url;
        } catch {
            return "https://bsc-dataseed.binance.org";
        }
    }

    function _computePancakePool(address deployer, address tokenA, address tokenB, uint24 fee)
        internal
        pure
        returns (address pool)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            deployer,
                            keccak256(abi.encode(token0, token1, fee)),
                            PANCAKE_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
}
