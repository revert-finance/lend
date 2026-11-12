// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/V3Oracle.sol";
import "../../src/V3Vault.sol";
import "../../src/InterestRateModel.sol";

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

    function setUp() public {
        require(block.chainid == 8453, "Run against Base fork");
        config = vm.readFile("config/aero-stock-collateral.json");
        npm = jsonVm.parseJsonAddress(config, ".npm");
        oracle = new V3Oracle(INonfungiblePositionManager(npm), USDC, address(0));
        InterestRateModel irm =
            new InterestRateModel(0, uint256(2 ** 64) * 13 / 100, 2 ** 64 * 3, uint256(2 ** 64) * 90 / 100);
        vault = IStockConfigVault(
            address(new V3Vault("Test", "TEST", USDC, INonfungiblePositionManager(npm), irm, oracle))
        );
        oracle.setMaxPoolPriceDifference(200);
        oracle.setSequencerUptimeFeed(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);
        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B),
            86400,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70),
            3600,
            IUniswapV3Pool(0x4A7af46bC8aBc00048c6c7920a1488DAF568366c),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            CBBTC,
            AggregatorV3Interface(0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D),
            86400,
            IUniswapV3Pool(0x784E539F15Ca2D19449a6311c5dAb6cF37d8f1ba),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        vault.setTokenConfig(USDC, uint32(uint256(85) * 2 ** 32 / 100), type(uint32).max);
        vault.setTokenConfig(WETH, uint32(uint256(775) * 2 ** 32 / 1000), type(uint32).max);
        vault.setTokenConfig(CBBTC, uint32(uint256(775) * 2 ** 32 / 1000), type(uint32).max);
        factor = uint32(jsonVm.parseJsonUint(config, ".collateralFactorBps") * 2 ** 32 / 10_000);
        cap = uint32(jsonVm.parseJsonUint(config, ".collateralValueLimitBps") * 2 ** 32 / 10_000);
        maxAge = uint32(jsonVm.parseJsonUint(config, ".maxFeedAge"));
        // B20 token metadata is native on Base, unavailable in stock Foundry's EVM.
        // Only decimals() is shimmed; oracle/vault are fresh, feeds and pools are real fork state.
        for (uint256 i; i < 3; ++i) {
            vm.mockCall(token(i), abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
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
        address pool = jsonVm.parseJsonAddress(config, string.concat(".assets[", vm.toString(i), "].pool"));
        vm.prank(oracle.owner());
        oracle.setTokenConfig(
            token(i), feed(i), maxAge, IUniswapV3Pool(pool), 60, V3Oracle.Mode.CHAINLINK_TWAP_VERIFY, 200
        );
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

    function testConfigureFreshDeploymentAndPreserveBasicCollateral() public {
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
            assertEq(address(actualFeed), address(feed(i)));
            assertEq(age, 86400);
            assertEq(fd, 8);
            assertEq(td, 8);
            assertEq(uint256(mode), uint256(V3Oracle.Mode.CHAINLINK_TWAP_VERIFY));
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
        vm.expectRevert(bytes4(keccak256("ChainlinkPriceError()")));
        oracle.getTokenValue(token(0), 1e8, USDC);
    }

    function testStockTwapDisagreementRejectsTokenValuation() public {
        configure();
        (uint80 id, int256 answer, uint256 start, uint256 updated, uint80 answered) = feed(0).latestRoundData();
        vm.mockCall(
            address(feed(0)),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer * 110 / 100, start, updated, answered)
        );
        vm.expectRevert(bytes4(keccak256("PriceDifferenceExceeded()")));
        oracle.getTokenValue(token(0), 1e8, USDC);
    }

    function testAllStockTokenUnitsAndOwedFeesConvertToUsdc() public {
        configure();
        (AggregatorV3Interface usdcFeed,,,,,,,,) = oracle.feedConfigs(USDC);
        (, int256 usdcAnswer,,,) = usdcFeed.latestRoundData();
        for (uint256 i; i < 3; ++i) {
            (, int256 stockAnswer,,,) = feed(i).latestRoundData();
            uint256 expected = FullMath.mulDiv(uint256(stockAnswer), 1e6, uint256(usdcAnswer));
            assertApproxEqAbs(oracle.getTokenValue(token(i), 1e8, USDC), expected, 1);
            // No liquidity, only known owed fees: 10 USDC and one whole 8-decimal stock.
            vm.mockCall(
                npm,
                abi.encodeWithSignature("positions(uint256)", 999_999_998),
                abi.encode(
                    uint96(0),
                    address(0),
                    USDC,
                    token(i),
                    uint24(10),
                    int24(-10000),
                    int24(10000),
                    uint128(0),
                    uint256(0),
                    uint256(0),
                    uint128(10e6),
                    uint128(1e8)
                )
            );
            (uint256 value, uint256 fees,,) = oracle.getValue(999_999_998, USDC, false);
            assertApproxEqAbs(value, expected + 10e6, 1);
            assertEq(fees, value);
            (value, fees,,) = oracle.getValue(999_999_998, USDC, true);
            assertEq(value, 0);
            assertEq(fees, 0);
        }
    }

    function testTwapModeRetainsPositionPoolDivergenceGuard() public {
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
