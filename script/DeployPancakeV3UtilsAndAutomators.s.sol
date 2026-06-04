// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../src/transformers/V3Utils.sol";
import "../src/transformers/AutoRange.sol";
import "../src/transformers/PancakeMasterChefV3AutoCompound.sol";
import "../src/automators/AutoExit.sol";
import "../src/automators/PancakeMasterChefV3Staker.sol";
import "../src/interfaces/pancake/IPancakeMasterChefV3.sol";

contract DeployPancakeV3UtilsAndAutomators is Script {
    error UnsupportedChain(uint256 chainId);
    error MissingContractCode(address target);
    error InvalidTwapConfig(uint32 twapSeconds, uint16 maxTwapTickDifference);
    error InvalidArrayLength(string key);
    error InvalidPancakeConfig();

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant BSC_CHAIN_ID = 56;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // PancakeSwap v3 addresses are the same on Ethereum, Arbitrum, and Base.
    address internal constant DEFAULT_PANCAKE_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant DEFAULT_PANCAKE_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant DEFAULT_PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant DEFAULT_PANCAKE_MASTER_CHEF_MAINNET = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant DEFAULT_PANCAKE_MASTER_CHEF_BASE = 0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3;
    address internal constant DEFAULT_PANCAKE_MASTER_CHEF_BSC = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant DEFAULT_PANCAKE_MASTER_CHEF_ARBITRUM = 0x5e09ACf80C0296740eC5d6F643005a4ef8DaA694;
    address internal constant DEFAULT_CAKE_MAINNET = 0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898;
    address internal constant DEFAULT_CAKE_BASE = 0x3055913c90Fcc1A6CE9a358911721eEb942013A1;
    address internal constant DEFAULT_CAKE_BSC = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant DEFAULT_CAKE_ARBITRUM = 0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c;

    // Conservative default anchors for dynamic CAKE reward routes.
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // Shared infra contracts across Ethereum, Arbitrum, and Base.
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEFAULT_ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Universal Router v2 defaults by chain (used by contracts when swapData is encoded in UR format).
    address internal constant DEFAULT_UNIVERSAL_ROUTER_MAINNET = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant DEFAULT_UNIVERSAL_ROUTER_ARBITRUM = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address internal constant DEFAULT_UNIVERSAL_ROUTER_BASE = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant DEFAULT_UNIVERSAL_ROUTER_BSC = 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07;

    // Default ownership recipients by chain.
    address internal constant DEFAULT_OWNER_MAINNET = 0xaac25e85e752425Dd1A92674CEeAF603758D3124;
    address internal constant DEFAULT_OWNER_ARBITRUM = 0x3e456ED2793988dc08f1482371b50bA2bC518175;
    address internal constant DEFAULT_OWNER_BASE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address internal constant DEFAULT_OPERATOR = 0xae886c189a289be69Fb0249F2F0793d7B1E51ceB;
    address internal constant DEFAULT_WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;

    struct DeployConfig {
        INonfungiblePositionManager npm;
        IPancakeMasterChefV3 masterChef;
        IERC20 cake;
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
        returns (
            V3Utils v3Utils,
            AutoRange autoRange,
            AutoExit autoExit,
            PancakeMasterChefV3Staker pancakeStaker,
            PancakeMasterChefV3AutoCompound pancakeAutoCompound
        )
    {
        _assertSupportedChain(block.chainid);

        DeployConfig memory config = _loadConfig();

        vm.startBroadcast();

        v3Utils = new V3Utils(config.npm, config.universalRouter, config.zeroxAllowanceHolder, config.permit2);
        autoRange = new AutoRange(
            config.npm,
            config.operator,
            config.withdrawer,
            config.twapSeconds,
            config.maxTwapTickDifference,
            config.universalRouter,
            config.zeroxAllowanceHolder
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
        if (address(config.masterChef) != address(0)) {
            pancakeStaker = new PancakeMasterChefV3Staker(config.npm, config.masterChef, config.cake);
            pancakeAutoCompound = new PancakeMasterChefV3AutoCompound(
                config.npm,
                config.cake,
                config.operator,
                config.withdrawer,
                config.twapSeconds,
                config.maxTwapTickDifference,
                config.universalRouter,
                config.zeroxAllowanceHolder
            );
            _configurePancakeAutoCompound(pancakeAutoCompound);
            _configurePancakeAutoRange(autoRange, config.cake);

            v3Utils.setPancakeStaker(address(pancakeStaker));
            autoRange.setPancakeStaker(address(pancakeStaker));
            autoExit.setPancakeStaker(address(pancakeStaker));
            pancakeAutoCompound.setPancakeStaker(address(pancakeStaker));

            pancakeStaker.setTransformer(address(v3Utils), true);
            pancakeStaker.setTransformer(address(autoRange), true);
            pancakeStaker.setTransformer(address(autoExit), true);
            pancakeStaker.setTransformer(address(pancakeAutoCompound), true);
        }

        // Ownable2Step contracts: set pending owner; OWNER must acceptOwnership() afterwards.
        if (config.owner != tx.origin) {
            v3Utils.transferOwnership(config.owner);
            autoRange.transferOwnership(config.owner);
            autoExit.transferOwnership(config.owner);
            if (address(pancakeStaker) != address(0)) {
                pancakeStaker.transferOwnership(config.owner);
            }
            if (address(pancakeAutoCompound) != address(0)) {
                pancakeAutoCompound.transferOwnership(config.owner);
            }
        }

        vm.stopBroadcast();

        console2.log("Network", _networkName(block.chainid));
        console2.log("PancakeFactory", DEFAULT_PANCAKE_FACTORY);
        console2.log("PancakeV3SwapRouter", DEFAULT_PANCAKE_V3_SWAP_ROUTER);
        console2.log("PancakeNPM", address(config.npm));
        console2.log("PancakeMasterChefV3", address(config.masterChef));
        console2.log("CAKE", address(config.cake));
        console2.log("UniversalRouter", config.universalRouter);
        console2.log("0xAllowanceHolder", config.zeroxAllowanceHolder);
        console2.log("Permit2", config.permit2);
        console2.log("Owner", config.owner);
        console2.log("V3Utils", address(v3Utils));
        console2.log("AutoRange", address(autoRange));
        console2.log("AutoExit", address(autoExit));
        console2.log("PancakeMasterChefV3Staker", address(pancakeStaker));
        console2.log("PancakeMasterChefV3AutoCompound", address(pancakeAutoCompound));
    }

    function _loadConfig() internal returns (DeployConfig memory config) {
        address npmAddress = _envOrAddress("PANCAKE_NPM", DEFAULT_PANCAKE_NPM);
        address masterChefAddress = _envOrAddress("PANCAKE_MASTER_CHEF_V3", _defaultMasterChef(block.chainid));
        address cakeAddress = _envOrAddress("CAKE", _defaultCake(block.chainid));
        address universalRouterDefault = _defaultUniversalRouter(block.chainid);
        address ownerDefault = _defaultOwner(block.chainid);

        config.npm = INonfungiblePositionManager(npmAddress);
        config.masterChef = IPancakeMasterChefV3(masterChefAddress);
        config.cake = IERC20(cakeAddress);
        config.universalRouter = _envOrAddress("UNIVERSAL_ROUTER", universalRouterDefault);
        config.zeroxAllowanceHolder = _envOrAddress("ZEROX_ALLOWANCE_HOLDER", DEFAULT_ZEROX_ALLOWANCE_HOLDER);
        config.permit2 = _envOrAddress("PERMIT2", DEFAULT_PERMIT2);
        config.owner = _envOrAddress("OWNER", ownerDefault == address(0) ? tx.origin : ownerDefault);
        config.operator = _envOrAddress("OPERATOR", DEFAULT_OPERATOR);
        config.withdrawer = _envOrAddress("WITHDRAWER", DEFAULT_WITHDRAWER);
        config.twapSeconds = uint32(_envOrUint("TWAP_SECONDS", 60));
        config.maxTwapTickDifference = uint16(_envOrUint("MAX_TWAP_TICK_DIFFERENCE", 100));

        if (config.owner == address(0) || config.operator == address(0) || config.withdrawer == address(0)) {
            revert InvalidPancakeConfig();
        }
        if (config.twapSeconds < 60 || config.maxTwapTickDifference > 200) {
            revert InvalidTwapConfig(config.twapSeconds, config.maxTwapTickDifference);
        }

        _assertContract(address(config.npm));
        if (address(config.masterChef) != address(0) || address(config.cake) != address(0)) {
            if (address(config.masterChef) == address(0) || address(config.cake) == address(0)) {
                revert InvalidPancakeConfig();
            }
            _assertContract(address(config.masterChef));
            _assertContract(address(config.cake));
            if (
                config.masterChef.CAKE() != address(config.cake)
                    || config.masterChef.nonfungiblePositionManager() != address(config.npm)
            ) {
                revert InvalidPancakeConfig();
            }
        }
        _assertContract(config.universalRouter);
        _assertContract(config.zeroxAllowanceHolder);
        _assertContract(config.permit2);
    }

    function _configurePancakeAutoCompound(PancakeMasterChefV3AutoCompound pancakeAutoCompound) internal {
        address[] memory anchorTokens =
            _envAddressArrayOrDefault("PANCAKE_REWARD_ANCHOR_TOKENS", _defaultRewardAnchorTokens(block.chainid));
        uint256[] memory anchorMinBalances = _envUintArrayOrDefault(
            "PANCAKE_REWARD_ANCHOR_MIN_BALANCES", _defaultRewardAnchorMinBalances(block.chainid)
        );
        if (anchorTokens.length != anchorMinBalances.length) {
            revert InvalidArrayLength("PANCAKE_REWARD_ANCHOR_TOKENS");
        }
        for (uint256 i; i < anchorTokens.length; ++i) {
            pancakeAutoCompound.setRewardAnchor(anchorTokens[i], anchorMinBalances[i]);
        }
    }

    function _configurePancakeAutoRange(AutoRange autoRange, IERC20 cake) internal {
        autoRange.setCakeToken(cake);
        address[] memory anchorTokens =
            _envAddressArrayOrDefault("PANCAKE_REWARD_ANCHOR_TOKENS", _defaultRewardAnchorTokens(block.chainid));
        uint256[] memory anchorMinBalances = _envUintArrayOrDefault(
            "PANCAKE_REWARD_ANCHOR_MIN_BALANCES", _defaultRewardAnchorMinBalances(block.chainid)
        );
        if (anchorTokens.length != anchorMinBalances.length) {
            revert InvalidArrayLength("PANCAKE_REWARD_ANCHOR_TOKENS");
        }
        for (uint256 i; i < anchorTokens.length; ++i) {
            autoRange.setRewardAnchor(anchorTokens[i], anchorMinBalances[i]);
        }
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

    function _envAddressArrayOrDefault(string memory key, address[] memory defaultValue)
        internal
        returns (address[] memory values)
    {
        try vm.envAddress(key, ",") returns (address[] memory parsed) {
            return parsed;
        } catch {
            return defaultValue;
        }
    }

    function _envUintArrayOrDefault(string memory key, uint256[] memory defaultValue)
        internal
        returns (uint256[] memory values)
    {
        try vm.envUint(key, ",") returns (uint256[] memory parsed) {
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
        if (chainId == BSC_CHAIN_ID) {
            return DEFAULT_UNIVERSAL_ROUTER_BSC;
        }
        revert UnsupportedChain(chainId);
    }

    function _defaultMasterChef(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET_CHAIN_ID) {
            return DEFAULT_PANCAKE_MASTER_CHEF_MAINNET;
        }
        if (chainId == BASE_CHAIN_ID) {
            return DEFAULT_PANCAKE_MASTER_CHEF_BASE;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return DEFAULT_PANCAKE_MASTER_CHEF_ARBITRUM;
        }
        if (chainId == BSC_CHAIN_ID) {
            return DEFAULT_PANCAKE_MASTER_CHEF_BSC;
        }
        return address(0);
    }

    function _defaultCake(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET_CHAIN_ID) {
            return DEFAULT_CAKE_MAINNET;
        }
        if (chainId == BASE_CHAIN_ID) {
            return DEFAULT_CAKE_BASE;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return DEFAULT_CAKE_ARBITRUM;
        }
        if (chainId == BSC_CHAIN_ID) {
            return DEFAULT_CAKE_BSC;
        }
        return address(0);
    }

    function _defaultRewardAnchorTokens(uint256 chainId) internal pure returns (address[] memory tokens) {
        if (chainId == MAINNET_CHAIN_ID) {
            tokens = new address[](1);
            tokens[0] = MAINNET_WETH;
            return tokens;
        }
        if (chainId == BASE_CHAIN_ID) {
            tokens = new address[](1);
            tokens[0] = BASE_WETH;
            return tokens;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            tokens = new address[](1);
            tokens[0] = ARBITRUM_WETH;
            return tokens;
        }
        if (chainId == BSC_CHAIN_ID) {
            tokens = new address[](2);
            tokens[0] = BSC_USDT;
            tokens[1] = BSC_WBNB;
            return tokens;
        }
        return new address[](0);
    }

    function _defaultRewardAnchorMinBalances(uint256 chainId) internal pure returns (uint256[] memory balances) {
        if (chainId == MAINNET_CHAIN_ID) {
            balances = new uint256[](1);
            balances[0] = 10e18; // WETH
            return balances;
        }
        if (chainId == BASE_CHAIN_ID) {
            balances = new uint256[](1);
            balances[0] = 10e18; // WETH
            return balances;
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            balances = new uint256[](1);
            balances[0] = 10e18; // WETH
            return balances;
        }
        if (chainId == BSC_CHAIN_ID) {
            balances = new uint256[](2);
            balances[0] = 100_000e18; // USDT
            balances[1] = 200e18; // WBNB
            return balances;
        }
        return new uint256[](0);
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
        if (chainId == BSC_CHAIN_ID) {
            return address(0);
        }
        revert UnsupportedChain(chainId);
    }

    function _assertSupportedChain(uint256 chainId) internal pure {
        if (
            chainId != MAINNET_CHAIN_ID && chainId != ARBITRUM_CHAIN_ID && chainId != BASE_CHAIN_ID
                && chainId != BSC_CHAIN_ID
        ) {
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
        if (chainId == BSC_CHAIN_ID) {
            return "bsc";
        }
        return "unsupported";
    }
}
