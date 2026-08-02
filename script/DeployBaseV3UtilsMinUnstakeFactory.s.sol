// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/transformers/V3Utils.sol";
import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

/// @notice Deploys a standalone V3Utils bound to the Aerodrome Slipstream "MinUnstake" CL
///         deployment on Base (aerodrome-finance/slipstream: DeployCL-Base-MinUnstake).
///         V3Utils binds to one NonfungiblePositionManager at construction, so each CL
///         factory needs its own instance. Swapper derives `factory` from npm.factory(),
///         so pool lookups resolve against this factory automatically.
///
///         Swaps route through the Aerodrome UniversalRouter or the 0x AllowanceHolder --
///         Swapper._routerSwap only understands those two ABIs, so a per-factory plain
///         SwapRouter must NOT be passed here.
contract DeployBaseV3UtilsMinUnstakeFactory is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // Base / Aerodrome CL "MinUnstake" deployment
    address internal constant AERODROME_NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
    address internal constant AERODROME_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;

    // Tokens
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // Routing infra
    address internal constant AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Known MinUnstake-factory pools used only as deployment sanity checks.
    address internal constant WETH_USDC_POOL_1 = 0x4e392fBfE4D0557C82D2F97F02ec39daA31516dd;
    address internal constant WETH_USDC_POOL_50 = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;
    address internal constant CBBTC_USDC_POOL_1 = 0x9D14ff91AE2c6e3D1A760542248B6c7F206894b0;

    function run() external returns (V3Utils v3Utils) {
        _validateDeploymentConfig();

        // Signer comes from the CLI (e.g. --account deployer). No PRIVATE_KEY required.
        vm.startBroadcast();
        v3Utils = new V3Utils(
            IAerodromeNonfungiblePositionManager(AERODROME_NPM), AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER
        );
        vm.stopBroadcast();

        console2.log("V3Utils", address(v3Utils));
    }

    function _validateDeploymentConfig() internal view {
        require(block.chainid == BASE_CHAIN_ID, "DeployBaseV3UtilsMinUnstakeFactory: wrong chain");
        _requireCode(AERODROME_NPM, "DeployBaseV3UtilsMinUnstakeFactory: NPM missing code");
        _requireCode(AERODROME_FACTORY, "DeployBaseV3UtilsMinUnstakeFactory: factory missing code");
        _requireCode(AERODROME_SWAP_ROUTER, "DeployBaseV3UtilsMinUnstakeFactory: router missing code");
        _requireCode(ZEROX_ALLOWANCE_HOLDER, "DeployBaseV3UtilsMinUnstakeFactory: allowance holder missing code");

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);
        require(npm.factory() == AERODROME_FACTORY, "DeployBaseV3UtilsMinUnstakeFactory: NPM factory mismatch");
        require(npm.WETH9() == WETH, "DeployBaseV3UtilsMinUnstakeFactory: NPM WETH mismatch");

        _validatePool(WETH_USDC_POOL_1, WETH, USDC, 1);
        _validatePool(WETH_USDC_POOL_50, WETH, USDC, 50);
        _validatePool(CBBTC_USDC_POOL_1, CBBTC, USDC, 1);
    }

    function _validatePool(address pool, address tokenA, address tokenB, int24 tickSpacing) internal view {
        _requireCode(pool, "DeployBaseV3UtilsMinUnstakeFactory: pool missing code");

        IAerodromeSlipstreamPool slipstreamPool = IAerodromeSlipstreamPool(pool);
        address resolved = IAerodromeSlipstreamFactory(AERODROME_FACTORY).getPool(tokenA, tokenB, tickSpacing);
        require(resolved == pool, "DeployBaseV3UtilsMinUnstakeFactory: factory pool mismatch");

        address poolToken0 = slipstreamPool.token0();
        address poolToken1 = slipstreamPool.token1();
        require(
            (poolToken0 == tokenA && poolToken1 == tokenB) || (poolToken0 == tokenB && poolToken1 == tokenA),
            "DeployBaseV3UtilsMinUnstakeFactory: token mismatch"
        );
        require(
            slipstreamPool.tickSpacing() == tickSpacing, "DeployBaseV3UtilsMinUnstakeFactory: tick spacing mismatch"
        );
        require(
            _readAddress(pool, "factory()") == AERODROME_FACTORY,
            "DeployBaseV3UtilsMinUnstakeFactory: pool factory mismatch"
        );
        require(_readAddress(pool, "nft()") == AERODROME_NPM, "DeployBaseV3UtilsMinUnstakeFactory: pool NPM mismatch");
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _readAddress(address target, string memory signature) internal view returns (address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && data.length >= 32, "DeployBaseV3UtilsMinUnstakeFactory: missing pool metadata");
        value = abi.decode(data, (address));
    }
}
