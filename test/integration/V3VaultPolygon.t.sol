// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// base contracts
import "../../src/V3Oracle.sol";
import "../../src/V3Vault.sol";
import "../../src/InterestRateModel.sol";

// transformers
import "../../src/transformers/LeverageTransformer.sol";
import "../../src/transformers/V3Utils.sol";
import "../../src/transformers/AutoRange.sol";
import "../../src/transformers/AutoCompound.sol";
import "../../src/automators/AutoExit.sol";

import "../../src/interfaces/IErrors.sol";

contract VaultPolygonIntegrationTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q96 = 2 ** 96;

    uint256 constant YEAR_SECS = 31557600; // taking into account leap years

    address constant WHALE_ACCOUNT = 0x9c2bd617b77961ee2c5e3038dFb0c822cb75d82a;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant WMATIC_USDC_005 = 0xA374094527e1673A86dE625aa59517c5dE346d32;

    address constant TEST_NFT_ACCOUNT = 0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB;
    uint256 constant TEST_NFT = 1052991;

    uint256 mainnetFork;

    V3Vault vault;

    InterestRateModel interestRateModel;
    V3Oracle oracle;

    V3Utils v3Utils;
    LeverageTransformer leverageTransformer;
    AutoRange autoRange;
    AutoCompound autoCompound;
    AutoExit autoExit;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/polygon", 50785039);
        vm.selectFork(mainnetFork);

        // 5% base rate - after 80% - 109% (like in compound v2 deployed)
        interestRateModel = new InterestRateModel(0, Q96 * 5 / 100, Q96 * 109 / 100, Q96 * 80 / 100);

        // use tolerant oracles (so timewarp for until 30 days works in tests - also allow divergence from price for mocked price results)
        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7),
            3600,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.TWAP,
            0
        );
        oracle.setTokenConfig(
            WMATIC,
            AggregatorV3Interface(0xAB594600376Ec9fD91F8e885dADF0CE036862dE0),
            3600,
            IUniswapV3Pool(WMATIC_USDC_005),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(0xF9680D99D6C9589e2a93a78A04A279e509205945),
            3600,
            IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );
        oracle.setTokenConfig(
            WBTC,
            AggregatorV3Interface(0xc907E116054Ad103354f2D350FD2514433D57F6f),
            3600,
            IUniswapV3Pool(0x847b64f9d3A95e977D157866447a5C0A5dFa0Ee5),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            200
        );

        vault =
            new V3Vault("Revert Lend USDC", "rlUSDC", address(USDC), NPM, interestRateModel, oracle, IPermit2(PERMIT2));
        vault.setTokenConfig(USDC, uint32(Q32 * 8 / 10), type(uint32).max); // 80% collateral factor / max 100% collateral value
        vault.setTokenConfig(WMATIC, uint32(Q32 * 8 / 10), type(uint32).max); // 80% collateral factor / max 100% collateral value
        vault.setTokenConfig(WETH, uint32(Q32 * 8 / 10), type(uint32).max); // 80% collateral factor / max 100% collateral value
        vault.setTokenConfig(WBTC, uint32(Q32 * 8 / 10), type(uint32).max); // 80% collateral factor / max 100% collateral value

        // limits 1000 USDC each
        vault.setLimits(0, 100000000, 100000000, 100000000, 100000000);

        // add transformers
        v3Utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);
        vault.setTransformer(address(v3Utils), true);

        leverageTransformer = new LeverageTransformer(NPM, EX0x, UNIVERSAL_ROUTER);
        vault.setTransformer(address(leverageTransformer), true);

        autoRange = new AutoRange(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100, EX0x, UNIVERSAL_ROUTER);
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault), true);

        autoCompound = new AutoCompound(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100);
        vault.setTransformer(address(autoCompound), true);
        autoCompound.setVault(address(vault), true);

        autoExit = new AutoExit(NPM, WHALE_ACCOUNT, WHALE_ACCOUNT, 60, 100, EX0x, UNIVERSAL_ROUTER);
        autoExit.setVault(address(vault), true);
    }

    function test() external {
        // lend 10 USDC
        vm.prank(WHALE_ACCOUNT);
        IERC20(USDC).approve(address(vault), 10000000);
        vm.prank(WHALE_ACCOUNT);
        vault.deposit(10000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vm.prank(TEST_NFT_ACCOUNT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(TEST_NFT);
        assertEq(collateralValue, 463959);
        assertEq(fullValue, 579950);

        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, collateralValue);
    }
}
