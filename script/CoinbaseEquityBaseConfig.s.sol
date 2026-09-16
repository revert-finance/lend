// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../lib/AggregatorV3Interface.sol";
import "../src/interfaces/IB20Multiplier.sol";

/// @dev forge 1.7 exposes vm.rpc but this forge-std Vm.sol predates it
interface VmRpc {
    function rpc(string calldata method, string calldata params) external returns (bytes memory data);
}

/// @notice Local-only stand-in for a B20 token, etched at the real token address during a script run.
/// @dev B20 tokens are native client code (`0xef`): a live Base node executes them, revm cannot. forge
///      always runs the script body locally, so any path that touches a B20 token (setTokenConfig ->
///      decimals(), adapter -> multiplier()) would revert before a single tx is broadcast. The stub
///      returns 8 decimals and the multiplier read from the live node via eth_call. It never leaves the
///      local run: broadcast txs execute against the real token on chain. Broadcast with
///      `--skip-simulation` so forge does not re-simulate the tx bundle without the stubs.
contract LocalB20Stub is IB20Multiplier {
    uint256 private multiplierValue; // slot 0, written with vm.store

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function multiplier() external view override returns (uint256) {
        return multiplierValue;
    }
}

/// @notice Single source of truth for the Coinbase B20 equity-collateral vault on Base:
///         every address and parameter in docs/plan-coinbase-equity-collateral-base-deployment.md §3.
///         Shared by the adapter deploy, vault deploy, verify and freeze scripts so they cannot drift.
abstract contract CoinbaseEquityBaseConfig is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;

    // Base / Aerodrome Slipstream "MinUnstake" CL deployment (all deep B20 pools live here)
    address internal constant AERODROME_NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
    address internal constant AERODROME_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    int24 internal constant EQUITY_TICK_SPACING = 10;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Routing infra. The UniversalRouter cannot reach MinUnstake pools; 0x covers B20<->USDC.
    address internal constant AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Reused MinUnstake-bound V3Utils (script/DEPLOY_AERODROME_V3UTILS.md); must be Safe-owned first
    address internal constant V3_UTILS = 0xc3cFFd675433f53aCc68D31288a4d31C085Fe2dD;

    // Production roles: 2-of-3 Safe, as rlAeroUSDC. No emergencyAdmin anywhere in the house.
    address internal constant BASE_MULTISIG = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;

    // Chainlink on Base
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant CHAINLINK_BASE_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // B20 policy registry precompile (monitoring only; not read by the protocol)
    address internal constant B20_POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;

    // Oracle parameters (plan §3)
    uint16 internal constant MAX_POOL_PRICE_DIFFERENCE = 300; // 3%
    uint32 internal constant TWAP_SECONDS = 60;
    uint32 internal constant EQUITY_MAX_FEED_AGE = 108_000; // 30h: > weekday gaps, < 52.45h weekend gap
    uint16 internal constant EQUITY_MAX_DIFFERENCE = 300; // 3%, never above (doubles as multiplier-error tolerance)
    uint32 internal constant USDC_MAX_FEED_AGE = 86_400;

    // Vault parameters (plan §3)
    string internal constant VAULT_NAME = "Revert Lend Coinbase Equities USDC";
    string internal constant VAULT_SYMBOL = "rlCbEqUSDC";
    uint32 internal constant CF_USDC_X32 = 3_650_722_201; // 85%
    uint32 internal constant CF_55_X32 = 2_362_232_012; // 55%
    uint32 internal constant CF_50_X32 = 2_147_483_648; // 50%
    uint32 internal constant RESERVE_FACTOR_X32 = 429_496_729; // 10%
    uint32 internal constant RESERVE_PROTECTION_FACTOR_X32 = 214_748_364; // 5%
    uint256 internal constant MIN_LOAN_SIZE = 1_000e6;
    uint256 internal constant GLOBAL_LEND_LIMIT = 2_000_000e6;
    uint256 internal constant GLOBAL_DEBT_LIMIT_LIVE = 1_000_000e6;
    uint256 internal constant DAILY_LEND_INCREASE_MIN = 200_000e6;
    uint256 internal constant DAILY_DEBT_INCREASE_MIN = 100_000e6;

    // pilot (half-size) per-name caps as a fraction of lentAssets
    uint32 internal constant CAP_GOOGLC_X32 = 257_698_037; // 6%
    uint32 internal constant CAP_METAC_X32 = 193_273_528; // 4.5%
    uint32 internal constant CAP_AAPLC_X32 = 171_798_691; // 4%
    uint32 internal constant CAP_NVDAC_X32 = 150_323_855; // 3.5%
    uint32 internal constant CAP_MSFTC_X32 = 107_374_182; // 2.5%
    uint32 internal constant CAP_AMZNC_X32 = 85_899_345; // 2%
    uint32 internal constant CAP_TSLAC_X32 = 64_424_509; // 1.5%

    struct Equity {
        string symbol;
        address token; // B20 token, 8 decimals
        address feed; // Chainlink "Coinbase TICKER", 8 decimals, per share
        address pool; // MinUnstake token/USDC pool, tickSpacing 10, token0 == USDC
        uint32 collateralFactorX32;
        uint32 collateralValueLimitFactorX32;
        string adapterEnv; // env var carrying the deployed ChainlinkMultiplierFeed address
    }

    function _equities() internal pure returns (Equity[7] memory e) {
        e[0] = Equity(
            "AAPLc",
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0x787f13dEa48Db0897CbCDD985de77809D837F988,
            0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0,
            CF_55_X32,
            CAP_AAPLC_X32,
            "ADAPTER_AAPLC"
        );
        e[1] = Equity(
            "MSFTc",
            0xB200000000000000000000Ab99cFa739E253872B,
            0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c,
            0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54,
            CF_55_X32,
            CAP_MSFTC_X32,
            "ADAPTER_MSFTC"
        );
        e[2] = Equity(
            "GOOGLc",
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
            0xB1987CAD1682841b4b641d50E520777eC5Ab5542,
            CF_55_X32,
            CAP_GOOGLC_X32,
            "ADAPTER_GOOGLC"
        );
        e[3] = Equity(
            "AMZNc",
            0xb200000000000000000000d9192b6B456483C2E8,
            0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
            0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b,
            CF_55_X32,
            CAP_AMZNC_X32,
            "ADAPTER_AMZNC"
        );
        e[4] = Equity(
            "METAc",
            0xb2000000000000000000008bC8786B856E61707C,
            0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
            0xEAF57753BC382E0324a1D43F72E7027705a2273E,
            CF_55_X32,
            CAP_METAC_X32,
            "ADAPTER_METAC"
        );
        e[5] = Equity(
            "NVDAc",
            0xb20000000000000000000078ee7ce2fE4908108C,
            0x04689a41629776563E6822F76f2e57D148d28513,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9,
            CF_50_X32,
            CAP_NVDAC_X32,
            "ADAPTER_NVDAC"
        );
        e[6] = Equity(
            "TSLAc",
            0xb2000000000000000000001e800a7f5189430cD0,
            0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4,
            0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB,
            CF_50_X32,
            CAP_TSLAC_X32,
            "ADAPTER_TSLAC"
        );
    }

    // ---- local B20 stand-ins ----------------------------------------------------------------------

    /// @dev live multiplier() via eth_call executed by the node (native B20 code); reverts if unavailable
    function _liveMultiplier(address token) internal returns (uint256) {
        string memory params = string.concat(
            '[{"to":"', vm.toString(token), '","data":"', vm.toString(abi.encodeWithSelector(IB20Multiplier.multiplier.selector)),
            '"},"latest"]'
        );
        bytes memory data = VmRpc(address(vm)).rpc("eth_call", params);
        require(data.length == 32, "CoinbaseEquity: live multiplier() call failed");
        uint256 m = abi.decode(data, (uint256));
        require(m > 0, "CoinbaseEquity: live multiplier() == 0");
        return m;
    }

    /// @dev etches LocalB20Stub at every equity token for the local script run; see LocalB20Stub
    function _installLocalB20Stubs(Equity[7] memory e) internal {
        for (uint256 i = 0; i < 7; i++) {
            _requireCode(e[i].token, string.concat("CoinbaseEquity: token missing code ", e[i].symbol));
            uint256 m = _liveMultiplier(e[i].token);
            vm.etch(e[i].token, type(LocalB20Stub).runtimeCode);
            vm.store(e[i].token, bytes32(0), bytes32(m));
            console2.log("LOCAL_B20_STUB", e[i].symbol, "multiplier", m);
        }
    }

    function _readAdapters(Equity[7] memory e) internal returns (address[7] memory adapters) {
        for (uint256 i = 0; i < 7; i++) {
            adapters[i] = vm.envAddress(e[i].adapterEnv);
            _requireCode(adapters[i], string.concat("CoinbaseEquity: adapter missing code ", e[i].symbol));
        }
    }

    // ---- shared validation -----------------------------------------------------------------------

    function _requireBaseInfra() internal view {
        require(block.chainid == BASE_CHAIN_ID, "CoinbaseEquity: wrong chain");
        _requireCode(AERODROME_NPM, "CoinbaseEquity: NPM missing code");
        _requireCode(AERODROME_FACTORY, "CoinbaseEquity: factory missing code");
        _requireCode(USDC, "CoinbaseEquity: USDC missing code");
        _requireCode(AERODROME_SWAP_ROUTER, "CoinbaseEquity: router missing code");
        _requireCode(ZEROX_ALLOWANCE_HOLDER, "CoinbaseEquity: allowance holder missing code");
        _requireCode(V3_UTILS, "CoinbaseEquity: V3Utils missing code");
        _requireCode(BASE_MULTISIG, "CoinbaseEquity: multisig missing code");
        _requireCode(CHAINLINK_USDC_USD, "CoinbaseEquity: USDC feed missing code");
        _requireCode(CHAINLINK_BASE_SEQUENCER_UPTIME_FEED, "CoinbaseEquity: sequencer feed missing code");
        require(
            IAerodromeNonfungiblePositionManager(AERODROME_NPM).factory() == AERODROME_FACTORY,
            "CoinbaseEquity: NPM factory mismatch"
        );
    }

    /// @dev pool linkage plus the TWAP liveness gate: observe([twap, 0]) must succeed (plan WP0.1)
    function _validateEquityPool(Equity memory e) internal view {
        _requireCode(e.pool, string.concat("CoinbaseEquity: pool missing code ", e.symbol));
        IAerodromeSlipstreamPool pool = IAerodromeSlipstreamPool(e.pool);
        require(
            IAerodromeSlipstreamFactory(AERODROME_FACTORY).getPool(e.token, USDC, EQUITY_TICK_SPACING) == e.pool,
            string.concat("CoinbaseEquity: factory pool mismatch ", e.symbol)
        );
        require(pool.token0() == USDC, string.concat("CoinbaseEquity: pool token0 not USDC ", e.symbol));
        require(pool.token1() == e.token, string.concat("CoinbaseEquity: pool token1 mismatch ", e.symbol));
        require(
            pool.tickSpacing() == EQUITY_TICK_SPACING, string.concat("CoinbaseEquity: tick spacing mismatch ", e.symbol)
        );
        require(
            _readAddress(e.pool, "factory()") == AERODROME_FACTORY,
            string.concat("CoinbaseEquity: pool factory mismatch ", e.symbol)
        );
        require(_readAddress(e.pool, "nft()") == AERODROME_NPM, string.concat("CoinbaseEquity: pool NPM mismatch ", e.symbol));

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_SECONDS;
        secondsAgos[1] = 0;
        (bool ok,) = e.pool.staticcall(abi.encodeWithSignature("observe(uint32[])", secondsAgos));
        require(ok, string.concat("CoinbaseEquity: observe(twap) fails ", e.symbol));
    }

    function _requireFreshFeed(address feed, uint32 maxFeedAge, string memory label) internal view returns (int256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, string.concat("CoinbaseEquity: feed answer <= 0 ", label));
        require(updatedAt + maxFeedAge >= block.timestamp, string.concat("CoinbaseEquity: feed stale ", label));
        return answer;
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _readAddress(address target, string memory signature) internal view returns (address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && data.length >= 32, string.concat("CoinbaseEquity: missing ", signature));
        value = abi.decode(data, (address));
    }

    function _logSafeTx(string memory label, address to, bytes memory data) internal view {
        console2.log("SAFE_TX", label);
        console2.log("  to   ", to);
        console2.log("  value", uint256(0));
        console2.log("  data ");
        console2.logBytes(data);
    }
}
