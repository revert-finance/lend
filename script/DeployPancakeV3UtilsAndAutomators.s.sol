// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../src/transformers/V3Utils.sol";
import "../src/transformers/AutoRange.sol";
import "../src/transformers/AutoCompound.sol";
import "../src/automators/AutoExit.sol";

contract DeployPancakeV3UtilsAndAutomators is Script {
    error UnsupportedChain(uint256 chainId);
    error MissingContractCode(address target);
    error InvalidTwapConfig(uint32 twapSeconds, uint16 maxTwapTickDifference);

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // PancakeSwap v3 addresses are the same on Ethereum, Arbitrum, and Base.
    address internal constant DEFAULT_PANCAKE_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant DEFAULT_PANCAKE_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant DEFAULT_PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    // Shared infra contracts across Ethereum, Arbitrum, and Base.
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEFAULT_ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Universal Router v2 defaults by chain (used by contracts when swapData is encoded in UR format).
    address internal constant DEFAULT_UNIVERSAL_ROUTER_MAINNET = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant DEFAULT_UNIVERSAL_ROUTER_ARBITRUM = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address internal constant DEFAULT_UNIVERSAL_ROUTER_BASE = 0x6fF5693b99212Da76ad316178A184AB56D299b43;

    // Default ownership recipients by chain.
    address internal constant DEFAULT_OWNER_MAINNET = 0xaac25e85e752425Dd1A92674CEeAF603758D3124;
    address internal constant DEFAULT_OWNER_ARBITRUM = 0x3e456ED2793988dc08f1482371b50bA2bC518175;
    address internal constant DEFAULT_OWNER_BASE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address internal constant DEFAULT_OPERATOR = 0xae886c189a289be69Fb0249F2F0793d7B1E51ceB;
    address internal constant DEFAULT_WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;

    struct DeployConfig {
        INonfungiblePositionManager npm;
        address universalRouter;
        address zeroxAllowanceHolder;
        address permit2;
        address owner;
        address operator;
        address withdrawer;
        uint32 twapSeconds;
        uint16 maxTwapTickDifference;
    }

    function run()
        external
        returns (V3Utils v3Utils, AutoRange autoRange, AutoCompound autoCompound, AutoExit autoExit)
    {
        _assertSupportedChain(block.chainid);

        DeployConfig memory config = _loadConfig();

        vm.startBroadcast();

        v3Utils = new V3Utils(
            config.npm, config.universalRouter, config.zeroxAllowanceHolder, config.permit2
        );
        autoRange = new AutoRange(
            config.npm,
            config.operator,
            config.withdrawer,
            config.twapSeconds,
            config.maxTwapTickDifference,
            config.universalRouter,
            config.zeroxAllowanceHolder
        );
        autoCompound = new AutoCompound(
            config.npm, config.operator, config.withdrawer, config.twapSeconds, config.maxTwapTickDifference
        );
        autoExit = new AutoExit(
            config.npm,
            config.operator,
            config.withdrawer,
            config.twapSeconds,
            config.maxTwapTickDifference,
            config.universalRouter,
            config.zeroxAllowanceHolder
        );

        // Ownable2Step contracts: set pending owner; OWNER must acceptOwnership() afterwards.
        if (config.owner != tx.origin) {
            v3Utils.transferOwnership(config.owner);
            autoRange.transferOwnership(config.owner);
            autoCompound.transferOwnership(config.owner);
            autoExit.transferOwnership(config.owner);
        }

        vm.stopBroadcast();

        console2.log("Network", _networkName(block.chainid));
        console2.log("PancakeFactory", DEFAULT_PANCAKE_FACTORY);
        console2.log("PancakeV3SwapRouter", DEFAULT_PANCAKE_V3_SWAP_ROUTER);
        console2.log("PancakeNPM", address(config.npm));
        console2.log("UniversalRouter", config.universalRouter);
        console2.log("0xAllowanceHolder", config.zeroxAllowanceHolder);
        console2.log("Permit2", config.permit2);
        console2.log("Owner", config.owner);
        console2.log("V3Utils", address(v3Utils));
        console2.log("AutoRange", address(autoRange));
        console2.log("AutoCompound", address(autoCompound));
        console2.log("AutoExit", address(autoExit));
    }

    function _loadConfig() internal returns (DeployConfig memory config) {
        address npmAddress = _envOrAddress("PANCAKE_NPM", DEFAULT_PANCAKE_NPM);
        address universalRouterDefault = _defaultUniversalRouter(block.chainid);

        config.npm = INonfungiblePositionManager(npmAddress);
        config.universalRouter = _envOrAddress("UNIVERSAL_ROUTER", universalRouterDefault);
        config.zeroxAllowanceHolder = _envOrAddress("ZEROX_ALLOWANCE_HOLDER", DEFAULT_ZEROX_ALLOWANCE_HOLDER);
        config.permit2 = _envOrAddress("PERMIT2", DEFAULT_PERMIT2);
        config.owner = _envOrAddress("OWNER", _defaultOwner(block.chainid));
        config.operator = _envOrAddress("OPERATOR", DEFAULT_OPERATOR);
        config.withdrawer = _envOrAddress("WITHDRAWER", DEFAULT_WITHDRAWER);
        config.twapSeconds = uint32(_envOrUint("TWAP_SECONDS", 60));
        config.maxTwapTickDifference = uint16(_envOrUint("MAX_TWAP_TICK_DIFFERENCE", 100));

        if (config.twapSeconds < 60 || config.maxTwapTickDifference > 200) {
            revert InvalidTwapConfig(config.twapSeconds, config.maxTwapTickDifference);
        }

        _assertContract(address(config.npm));
        _assertContract(config.universalRouter);
        _assertContract(config.zeroxAllowanceHolder);
        _assertContract(config.permit2);
    }

    function _envOrAddress(string memory key, address defaultValue) internal returns (address value) {
        try vm.envAddress(key) returns (address parsed) {
            return parsed;
        } catch {
            return defaultValue;
        }
    }

    function _envOrUint(string memory key, uint256 defaultValue) internal returns (uint256 value) {
        try vm.envUint(key) returns (uint256 parsed) {
            return parsed;
        } catch {
            return defaultValue;
        }
    }

    function _defaultUniversalRouter(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET_CHAIN_ID) {
            return DEFAULT_UNIVERSAL_ROUTER_MAINNET;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return DEFAULT_UNIVERSAL_ROUTER_ARBITRUM;
        }
        if (chainId == BASE_CHAIN_ID) {
            return DEFAULT_UNIVERSAL_ROUTER_BASE;
        }
        revert UnsupportedChain(chainId);
    }

    function _defaultOwner(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET_CHAIN_ID) {
            return DEFAULT_OWNER_MAINNET;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return DEFAULT_OWNER_ARBITRUM;
        }
        if (chainId == BASE_CHAIN_ID) {
            return DEFAULT_OWNER_BASE;
        }
        revert UnsupportedChain(chainId);
    }

    function _assertSupportedChain(uint256 chainId) internal pure {
        if (chainId != MAINNET_CHAIN_ID && chainId != ARBITRUM_CHAIN_ID && chainId != BASE_CHAIN_ID) {
            revert UnsupportedChain(chainId);
        }
    }

    function _assertContract(address target) internal view {
        if (target.code.length == 0) {
            revert MissingContractCode(target);
        }
    }

    function _networkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == MAINNET_CHAIN_ID) {
            return "mainnet";
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return "arbitrum";
        }
        if (chainId == BASE_CHAIN_ID) {
            return "base";
        }
        return "unsupported";
    }
}
