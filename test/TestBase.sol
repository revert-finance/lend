// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../src/V3Utils.sol";
import "../src/Holder.sol";
import "../src/runners/RangeAdjustor.sol";

import "../src/modules/CompoundorModule.sol";
import "../src/modules/StopLossLimitModule.sol";
import "../src/modules/LockModule.sol";
import "../src/modules/CollateralModule.sol";

import "../src/compound/Unitroller.sol";
import "../src/compound/Comptroller.sol";
import "../src/compound/WhitePaperInterestRateModel.sol";
import "../src/compound/CErc20Delegate.sol";
import "../src/compound/CErc20Delegator.sol";


abstract contract TestBase is Test {
    
    uint256 constant Q64 = 2**64;

    int24 constant MIN_TICK_100 = -887272;
    int24 constant MIN_TICK_500 = -887270;

    IERC20 constant WETH_ERC20 = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant OPERATOR_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    address FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy

    address constant COMPOUND_COMPTROLLER = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B; 
    address constant COMPOUND_ORACLE = 0x65c816077C29b557BEE980ae3cC2dCE80204A0C5; // current compound oracle

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // DAI/USDC 0.05% - one sided only DAI - current tick is near -276326 - no liquidity (-276320/-276310)
    uint256 constant TEST_NFT = 24181;
    address constant TEST_NFT_ACCOUNT = 0x8cadb20A4811f363Dadb863A190708bEd26245F8;
    address constant TEST_NFT_POOL = 0x6c6Bc977E13Df9b0de53b251522280BB72383700;
   
    uint256 constant TEST_NFT_2 = 7;  // DAI/WETH 0.3% - one sided only WETH - with liquidity and fees (-84120/-78240)
    uint256 constant TEST_NFT_2_A = 126; // DAI/USDC 0.05% - in range (-276330/-276320)
    uint256 constant TEST_NFT_2_B = 37; // USDC/WETH 0.3% - out of range (192180/193380)
    address constant TEST_NFT_2_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    address constant TEST_NFT_2_POOL = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;

    // DAI/USDC 0.05% - in range - with liquidity and fees
    uint256 constant TEST_NFT_3 = 4660; 
    address constant TEST_NFT_3_ACCOUNT = 0xa3eF006a7da5BcD1144d8BB86EfF1734f46A0c1E;
    address constant TEST_NFT_3_POOL = 0x6c6Bc977E13Df9b0de53b251522280BB72383700;

    // USDC/WETH 0.3% - in range - with liquidity and fees
    uint constant TEST_NFT_4 = 827;
    address constant TEST_NFT_4_ACCOUNT = 0x96653b13bD00842Eb8Bc77dCCFd48075178733ce;
    address constant TEST_NFT_4_POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    // DAI/USDC 0.05% - in range - with liquidity and fees
    uint constant TEST_NFT_5 = 23901;
    address constant TEST_NFT_5_ACCOUNT = 0x082d3e0f04664b65127876e9A05e2183451c792a;

    address constant TEST_FEE_ACCOUNT = 0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB;

    uint256 mainnetFork;

    Holder holder;
    V3Utils v3utils;
    RangeAdjustor rangeAdjustor;

    CompoundorModule compoundorModule;
    StopLossLimitModule stopLossLimitModule;
    LockModule lockModule;

    CollateralModule collateralModule;

    ChainlinkOracle oracle;
    Unitroller unitroller;
    Comptroller comptroller;
    InterestRateModel irm;
    CErc20 cTokenUSDC;
    CErc20 cTokenDAI;
    CErc20 cTokenWETH;
    CErc20Delegate cErc20Delegate;

    function _setupBase() internal {

        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);

        holder = new Holder(NPM);
        v3utils = new V3Utils(NPM, EX0x);

        // runners
        rangeAdjustor = new RangeAdjustor(v3utils, OPERATOR_ACCOUNT, 60, 100);

        holder.setFlashTransformContract(address(v3utils));
    }

    function _setupCompoundorModule(uint blocking) internal returns (uint8) {
        compoundorModule = new CompoundorModule(NPM);
        compoundorModule.setHolder(holder);
        return holder.addModule(compoundorModule, blocking);
    }

    function _setupStopLossLimitModule(uint blocking) internal returns (uint8) {
        stopLossLimitModule = new StopLossLimitModule(NPM, EX0x, OPERATOR_ACCOUNT, 60, 100);
        stopLossLimitModule.setHolder(holder);
        assertEq(address(stopLossLimitModule.factory()), FACTORY);

        return holder.addModule(stopLossLimitModule, blocking);
    }

    function _setupLockModule(uint blocking) internal returns (uint8) {
        lockModule = new LockModule(NPM);
        lockModule.setHolder(holder);
        assertEq(address(lockModule.factory()), FACTORY);

        return holder.addModule(lockModule, blocking);
    }

    function _setupCollateralModule(uint blocking) internal returns (uint8) {

        // SETUP complete custom COMPOUND
        unitroller = new Unitroller();
        comptroller = new Comptroller();

        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);

        // change comptroller to proxy unitroller
        comptroller = Comptroller(address(unitroller));

        // value from mainnet comptroller
        comptroller._setCloseFactor(500000000000000000); // 50%
        comptroller._setLiquidationIncentive(1080000000000000000); // 108%

        irm = new WhitePaperInterestRateModel(20000000000000000, 300000000000000000);

        cErc20Delegate = new CErc20Delegate();

        cTokenUSDC = CErc20(address(new CErc20Delegator(address(USDC), comptroller, irm, 1 ether, "cUSDC", "cUSDC", 8, payable(address(this)), address(cErc20Delegate), "")));
        cTokenDAI = CErc20(address(new CErc20Delegator(address(DAI), comptroller, irm, 1 ether, "cDAI", "cDAI", 8, payable(address(this)), address(cErc20Delegate), "")));
        cTokenWETH = CErc20(address(new CErc20Delegator(address(WETH_ERC20), comptroller, irm, 1 ether, "cWETH", "cWETH", 8, payable(address(this)), address(cErc20Delegate), "")));

        oracle = new ChainlinkOracle();
        oracle.setTokenFeed(address(cTokenUSDC), AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 48);
        oracle.setTokenFeed(address(cTokenDAI), AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 48);
        oracle.setTokenFeed(address(cTokenWETH), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600);
        comptroller._setPriceOracle(oracle);

        uint64 fiftyPercent = 5 * 10 ** 17;

        comptroller._supportMarket(cTokenUSDC);
        comptroller._setCollateralFactor(cTokenUSDC, fiftyPercent);
        comptroller._supportMarket(cTokenDAI);
        comptroller._setCollateralFactor(cTokenDAI, fiftyPercent);
        comptroller._supportMarket(cTokenWETH);
        comptroller._setCollateralFactor(cTokenWETH, fiftyPercent);

        collateralModule = new CollateralModule(NPM, address(comptroller), 60);
        collateralModule.setHolder(holder);

        // link module to comptroller
        comptroller._setCollateralModule(collateralModule);

        collateralModule.setPoolConfig(TEST_NFT_3_POOL, true, uint64(Q64 / 100));
        collateralModule.setPoolConfig(TEST_NFT_4_POOL, true, uint64(Q64 / 100));
        collateralModule.setPoolConfig(TEST_NFT_2_POOL, true, uint64(Q64 / 100));

        return holder.addModule(collateralModule, blocking);
    }
}