// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/V3Oracle.sol";
import "../../src/oracles/StockTwapFeed.sol";

interface IStockJsonVm {
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
}

interface IStockConfigVault {
    function owner() external view returns (address);
    function oracle() external view returns (address);
    function setTokenConfig(address, uint32, uint32) external;
    function tokenConfigs(address) external view returns (uint32, uint32, uint192);
}

contract AeroStockCollateralTest is Test {
    IStockJsonVm constant jsonVm = IStockJsonVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string config;
    V3Oracle oracle;
    IStockConfigVault vault;
    address npm;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint32 factor;
    uint32 cap;
    uint32 maxAge;
    StockTwapFeed[3] adapters;

    function setUp() public {
        require(block.chainid == 8453, "Run against Base fork");
        config = vm.readFile("config/aero-stock-collateral.json");
        oracle = V3Oracle(jsonVm.parseJsonAddress(config, ".oracle"));
        vault = IStockConfigVault(jsonVm.parseJsonAddress(config, ".vault"));
        npm = jsonVm.parseJsonAddress(config, ".npm");
        factor = uint32(jsonVm.parseJsonUint(config, ".collateralFactorBps") * 2 ** 32 / 10_000);
        cap = uint32(jsonVm.parseJsonUint(config, ".collateralValueLimitBps") * 2 ** 32 / 10_000);
        maxAge = uint32(jsonVm.parseJsonUint(config, ".maxFeedAge"));
        // B20 token metadata is native on Base, unavailable in stock Foundry's EVM.
        // Only decimals() is shimmed; feeds, owners, oracle, vault and pools are real fork state.
        for (uint256 i; i < 3; ++i) {
            vm.mockCall(token(i), abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
            address pool = jsonVm.parseJsonAddress(config, string.concat(".assets[", vm.toString(i), "].pool"));
            require(
                IAerodromeSlipstreamFactory(oracle.factory())
                        .getPool(USDC, token(i), IUniswapV3Pool(pool).tickSpacing()) == pool
            );
            adapters[i] = new StockTwapFeed(
                feed(i),
                AggregatorV3Interface(jsonVm.parseJsonAddress(config, ".usdcFeed")),
                IUniswapV3Pool(pool),
                token(i),
                USDC,
                maxAge,
                uint32(jsonVm.parseJsonUint(config, ".maxUsdcFeedAge")),
                uint32(jsonVm.parseJsonUint(config, ".twapSeconds")),
                uint16(jsonVm.parseJsonUint(config, ".maxDifferenceBps"))
            );
        }
    }

    function token(uint256 i) internal returns (address) {
        return jsonVm.parseJsonAddress(config, string.concat(".assets[", vm.toString(i), "].token"));
    }

    function feed(uint256 i) internal returns (AggregatorV3Interface) {
        return
            AggregatorV3Interface(jsonVm.parseJsonAddress(config, string.concat(".assets[", vm.toString(i), "].feed")));
    }

    function configureOracle(uint256 i) internal {
        vm.prank(oracle.owner());
        oracle.setTokenConfig(token(i), adapters[i], maxAge, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.CHAINLINK, 0);
    }

    function configure() internal {
        for (uint256 i; i < 3; ++i) {
            configureOracle(i);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(vault.owner());
            vault.setTokenConfig(token(i), factor, cap);
        }
    }

    function existingConfigHash() internal view returns (bytes32) {
        bytes memory data;
        address[3] memory existing = [USDC, WETH, CBBTC];
        for (uint256 i; i < existing.length; ++i) {
            (bool a, bytes memory x) =
                address(oracle).staticcall(abi.encodeWithSignature("feedConfigs(address)", existing[i]));
            (bool b, bytes memory y) =
                address(vault).staticcall(abi.encodeWithSignature("tokenConfigs(address)", existing[i]));
            require(a && b);
            data = bytes.concat(data, x, y);
        }
        return keccak256(data);
    }

    function testConfigureExistingDeploymentAndPreserveExistingCollateral() public {
        bytes32 beforeConfig = existingConfigHash();
        address ownerBefore = oracle.owner();
        assertEq(vault.oracle(), address(oracle));
        configure();
        assertEq(existingConfigHash(), beforeConfig);
        assertEq(oracle.owner(), ownerBefore);
        assertEq(oracle.maxPoolPriceDifference(), 200);
        assertEq(factor, 2 ** 31);
        assertEq(cap, uint32(uint256(5) * 2 ** 32 / 100));
        for (uint256 i; i < 3; ++i) {
            (AggregatorV3Interface actualFeed, uint32 age, uint8 fd, uint8 td,,,, V3Oracle.Mode mode,) =
                oracle.feedConfigs(token(i));
            assertEq(address(actualFeed), address(adapters[i]));
            assertEq(age, 86400);
            assertEq(fd, 8);
            assertEq(td, 8);
            assertEq(uint256(mode), uint256(V3Oracle.Mode.CHAINLINK));
            (uint32 cf, uint32 limit,) = vault.tokenConfigs(token(i));
            assertEq(cf, factor);
            assertEq(limit, cap);
            assertGt(oracle.getTokenValue(token(i), 1e8, USDC), 0);
        }
        configure(); // Resuming/reapplying does not change existing asset configuration.
        assertEq(existingConfigHash(), beforeConfig);
    }

    function testUnprivilegedCallerCannotEnableCollateral() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.setTokenConfig(token(0), factor, cap);
    }

    function testStaleStockFeedRejectsValuation() public {
        configure();
        (, int256 answer,,,) = feed(0).latestRoundData();
        uint256 staleAt = block.timestamp - maxAge - 1;
        vm.mockCall(
            address(feed(0)),
            abi.encodeWithSelector(feed(0).latestRoundData.selector),
            abi.encode(uint80(1), answer, staleAt, staleAt, uint80(1))
        );
        vm.expectRevert(StockTwapFeed.InvalidRound.selector);
        oracle.getTokenValue(token(0), 1e8, USDC);
    }

    function testAdapterRoundMatchesUnderlyingOnRealPools() public {
        for (uint256 i; i < 3; ++i) {
            (bool a, bytes memory actual) =
                address(adapters[i]).staticcall(abi.encodeWithSignature("latestRoundData()"));
            (bool b, bytes memory original) = address(feed(i)).staticcall(abi.encodeWithSignature("latestRoundData()"));
            assertTrue(a && b);
            assertEq(actual, original);
        }
    }

    function testExistingOracleRejectsStockTwapDisagreement() public {
        configure();
        (uint80 round, int256 answer, uint256 start, uint256 updated, uint80 answered) = feed(0).latestRoundData();
        vm.mockCall(
            address(feed(0)),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(round, answer * 110 / 100, start, updated, answered)
        );
        vm.expectRevert(StockTwapFeed.PriceDifferenceExceeded.selector);
        oracle.getTokenValue(token(0), 1e8, USDC);
    }

    function testChainlinkModeRetainsPositionPoolDivergenceGuard() public {
        configure();
        address pool = IAerodromeSlipstreamFactory(oracle.factory()).getPool(USDC, token(0), 10);
        assertTrue(pool != address(0));
        // Synthetic NFT metadata only; resolve and value against the actual factory/pool/feeds.
        vm.mockCall(
            npm,
            abi.encodeWithSignature("positions(uint256)", 999_999_999),
            abi.encode(
                uint96(0),
                address(0),
                USDC,
                token(0),
                uint24(10),
                int24(-10000),
                int24(10000),
                uint128(1e10),
                uint256(0),
                uint256(0),
                uint128(0),
                uint128(0)
            )
        );
        (uint256 value,,,) = oracle.getValue(999_999_999, USDC, true);
        assertGt(value, 0);
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok);
        (uint160 sqrtPrice, int24 tick, uint16 index, uint16 cardinality, uint16 next, bool unlocked) =
            abi.decode(data, (uint160, int24, uint16, uint16, uint16, bool));
        vm.mockCall(
            pool,
            abi.encodeWithSignature("slot0()"),
            abi.encode(uint160(uint256(sqrtPrice) * 110 / 100), tick, index, cardinality, next, unlocked)
        );
        vm.expectRevert(bytes4(keccak256("PriceDifferenceExceeded()")));
        oracle.getValue(999_999_999, USDC, true);
    }
}
