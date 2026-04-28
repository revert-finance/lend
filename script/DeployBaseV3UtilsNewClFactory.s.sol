// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/transformers/V3Utils.sol";
import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

contract DeployBaseV3UtilsNewClFactory is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // Base / Aerodrome CL v2
    address internal constant AERODROME_NPM = 0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F;
    address internal constant AERODROME_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;

    // Tokens
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    // Routing infra
    address internal constant AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Known new-factory pools used only as deployment sanity checks.
    address internal constant WETH_USDC_POOL_50 = 0xc758d81B9b81A6FCDAd075bD471874A2c46B54e0;
    address internal constant WETH_USDC_POOL_500 = 0x56AeaF4af2DF4bdFD9D865830Fefdd278b25E7Ef;
    address internal constant CBBTC_USDC_POOL_1 = 0x95DaDA6BC214A86Af204250F7b6FF873b52e0289;

    function run() external returns (V3Utils v3Utils) {
        _validateDeploymentConfig();

        vm.envUint("PRIVATE_KEY");
        vm.startBroadcast();
        v3Utils = new V3Utils(
            IAerodromeNonfungiblePositionManager(AERODROME_NPM), AERODROME_SWAP_ROUTER, ZEROX_ALLOWANCE_HOLDER
        );
        vm.stopBroadcast();

        console2.log("V3Utils", address(v3Utils));
    }

    function _validateDeploymentConfig() internal view {
        require(block.chainid == BASE_CHAIN_ID, "DeployBaseV3UtilsNewClFactory: wrong chain");
        _requireCode(AERODROME_NPM, "DeployBaseV3UtilsNewClFactory: NPM missing code");
        _requireCode(AERODROME_FACTORY, "DeployBaseV3UtilsNewClFactory: factory missing code");
        _requireCode(AERODROME_SWAP_ROUTER, "DeployBaseV3UtilsNewClFactory: router missing code");
        _requireCode(ZEROX_ALLOWANCE_HOLDER, "DeployBaseV3UtilsNewClFactory: allowance holder missing code");

        IAerodromeNonfungiblePositionManager npm = IAerodromeNonfungiblePositionManager(AERODROME_NPM);
        require(npm.factory() == AERODROME_FACTORY, "DeployBaseV3UtilsNewClFactory: NPM factory mismatch");
        require(npm.WETH9() == WETH, "DeployBaseV3UtilsNewClFactory: NPM WETH mismatch");

        _validatePool(WETH_USDC_POOL_50, WETH, USDC, 50);
        _validatePool(WETH_USDC_POOL_500, WETH, USDC, 500);
        _validatePool(CBBTC_USDC_POOL_1, CBBTC, USDC, 1);
    }

    function _validatePool(address pool, address tokenA, address tokenB, int24 tickSpacing) internal view {
        _requireCode(pool, "DeployBaseV3UtilsNewClFactory: pool missing code");

        IAerodromeSlipstreamPool slipstreamPool = IAerodromeSlipstreamPool(pool);
        address resolved = IAerodromeSlipstreamFactory(AERODROME_FACTORY).getPool(tokenA, tokenB, tickSpacing);
        require(resolved == pool, "DeployBaseV3UtilsNewClFactory: factory pool mismatch");

        address poolToken0 = slipstreamPool.token0();
        address poolToken1 = slipstreamPool.token1();
        require(
            (poolToken0 == tokenA && poolToken1 == tokenB) || (poolToken0 == tokenB && poolToken1 == tokenA),
            "DeployBaseV3UtilsNewClFactory: token mismatch"
        );
        require(slipstreamPool.tickSpacing() == tickSpacing, "DeployBaseV3UtilsNewClFactory: tick spacing mismatch");
        require(
            _readAddress(pool, "factory()") == AERODROME_FACTORY, "DeployBaseV3UtilsNewClFactory: pool factory mismatch"
        );
        require(_readAddress(pool, "nft()") == AERODROME_NPM, "DeployBaseV3UtilsNewClFactory: pool NPM mismatch");
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _readAddress(address target, string memory signature) internal view returns (address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && data.length >= 32, "DeployBaseV3UtilsNewClFactory: missing pool metadata");
        value = abi.decode(data, (address));
    }
}
