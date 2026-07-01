// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../src/transformers/AutoRange.sol";

interface ITransformerVault {
    function owner() external view returns (address);
    function nonfungiblePositionManager() external view returns (address);
    function setTransformer(address transformer, bool active) external;
}

interface IOwnable2StepLike {
    function acceptOwnership() external;
}

contract DeployAutoRangeFix is Script {
    error UnsupportedChain(uint256 chainId);
    error MissingContractCode(address target);
    error InvalidAddressEnv(string key, string value);
    error InvalidUintEnv(string key, string value);
    error InvalidTwapConfig(uint32 twapSeconds, uint16 maxTwapTickDifference);
    error InvalidVaultNpm(address vaultNpm, address expectedNpm);

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    address internal constant UNISWAP_NPM_MAINNET_AND_ARBITRUM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNISWAP_NPM_BASE = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    address internal constant MAINNET_VAULT = 0xa2754543f69dC036764bBfad16d2A74F5cD15667;
    address internal constant ARBITRUM_VAULT = 0x74E6AFeF5705BEb126C6d3Bf46f8fad8F3e07825;
    address internal constant BASE_VAULT = 0x36AEAe0E411a1E28372e0d66f02E57744EbE7599;

    address internal constant MAINNET_OLD_AUTO_RANGE = 0x88481E2Fbc98d4a251655B0F1A4422555EA72d9E;
    address internal constant ARBITRUM_OLD_AUTO_RANGE = 0x5ff2195BA28d2544AeD91e30e5f74B87d4F158dE;
    address internal constant BASE_OLD_AUTO_RANGE = 0xA8549424B20a514Eb9e7a829ec013065Bef9Dc1D;

    address internal constant MAINNET_OWNER = 0xaac25e85e752425Dd1A92674CEeAF603758D3124;
    address internal constant ARBITRUM_OWNER = 0x3e456ED2793988dc08f1482371b50bA2bC518175;
    address internal constant BASE_OWNER = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;

    address internal constant MAINNET_UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address internal constant ARBITRUM_UNIVERSAL_ROUTER = 0x5E325eDA8064b456f4781070C0738d849c824258;
    address internal constant BASE_UNIVERSAL_ROUTER = 0xeC8B0F7Ffe3ae75d7FfAb09429e3675bb63503e4;

    address internal constant DEFAULT_ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant DEFAULT_WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;

    struct DeployConfig {
        string networkName;
        address npm;
        address vault;
        address oldAutoRange;
        address owner;
        address operator;
        address withdrawer;
        address universalRouter;
        address zeroxAllowanceHolder;
        uint32 twapSeconds;
        uint16 maxTwapTickDifference;
    }

    function run() external returns (AutoRange autoRange) {
        DeployConfig memory config = _loadConfig();

        _assertContract(config.npm);
        _assertContract(config.vault);
        _assertContract(config.universalRouter);
        _assertContract(config.zeroxAllowanceHolder);
        _assertVaultNpm(config.vault, config.npm);

        vm.startBroadcast();

        autoRange = new AutoRange(
            INonfungiblePositionManager(config.npm),
            config.operator,
            config.withdrawer,
            config.twapSeconds,
            config.maxTwapTickDifference,
            config.universalRouter,
            config.zeroxAllowanceHolder
        );

        autoRange.setVault(config.vault);

        if (config.owner != tx.origin) {
            autoRange.transferOwnership(config.owner);
        }

        vm.stopBroadcast();

        _logDeployment(config, address(autoRange));
    }

    function _loadConfig() internal returns (DeployConfig memory config) {
        config = _defaultConfig(block.chainid);

        config.owner = _envOrAddress("OWNER", config.owner);
        config.operator = _envOrAddress("OPERATOR", address(0));
        config.withdrawer = _envOrAddress("WITHDRAWER", config.withdrawer);
        config.universalRouter = _envOrAddress("UNIVERSAL_ROUTER", config.universalRouter);
        config.zeroxAllowanceHolder = _envOrAddress("ZEROX_ALLOWANCE_HOLDER", config.zeroxAllowanceHolder);
        config.twapSeconds = _envOrUint32("TWAP_SECONDS", config.twapSeconds);
        config.maxTwapTickDifference = _envOrUint16("MAX_TWAP_TICK_DIFFERENCE", config.maxTwapTickDifference);

        if (config.twapSeconds < 60 || config.maxTwapTickDifference > 200) {
            revert InvalidTwapConfig(config.twapSeconds, config.maxTwapTickDifference);
        }
    }

    function _defaultConfig(uint256 chainId) internal pure returns (DeployConfig memory config) {
        if (chainId == MAINNET_CHAIN_ID) {
            return DeployConfig({
                networkName: "mainnet",
                npm: UNISWAP_NPM_MAINNET_AND_ARBITRUM,
                vault: MAINNET_VAULT,
                oldAutoRange: MAINNET_OLD_AUTO_RANGE,
                owner: MAINNET_OWNER,
                operator: address(0),
                withdrawer: DEFAULT_WITHDRAWER,
                twapSeconds: 60,
                maxTwapTickDifference: 100,
                universalRouter: MAINNET_UNIVERSAL_ROUTER,
                zeroxAllowanceHolder: DEFAULT_ZEROX_ALLOWANCE_HOLDER
            });
        }
        if (chainId == ARBITRUM_CHAIN_ID) {
            return DeployConfig({
                networkName: "arbitrum",
                npm: UNISWAP_NPM_MAINNET_AND_ARBITRUM,
                vault: ARBITRUM_VAULT,
                oldAutoRange: ARBITRUM_OLD_AUTO_RANGE,
                owner: ARBITRUM_OWNER,
                operator: address(0),
                withdrawer: DEFAULT_WITHDRAWER,
                twapSeconds: 60,
                maxTwapTickDifference: 100,
                universalRouter: ARBITRUM_UNIVERSAL_ROUTER,
                zeroxAllowanceHolder: DEFAULT_ZEROX_ALLOWANCE_HOLDER
            });
        }
        if (chainId == BASE_CHAIN_ID) {
            return DeployConfig({
                networkName: "base",
                npm: UNISWAP_NPM_BASE,
                vault: BASE_VAULT,
                oldAutoRange: BASE_OLD_AUTO_RANGE,
                owner: BASE_OWNER,
                operator: address(0),
                withdrawer: DEFAULT_WITHDRAWER,
                twapSeconds: 60,
                maxTwapTickDifference: 100,
                universalRouter: BASE_UNIVERSAL_ROUTER,
                zeroxAllowanceHolder: DEFAULT_ZEROX_ALLOWANCE_HOLDER
            });
        }
        revert UnsupportedChain(chainId);
    }

    function _logDeployment(DeployConfig memory config, address newAutoRange) internal view {
        address vaultOwner = ITransformerVault(config.vault).owner();

        console2.log("Network", config.networkName);
        console2.log("NewAutoRange", newAutoRange);
        console2.log("OldAutoRange", config.oldAutoRange);
        console2.log("Vault", config.vault);
        console2.log("VaultOwner", vaultOwner);
        console2.log("AutoRangeOwner", config.owner);
        console2.log("Operator", config.operator);
        console2.log("Withdrawer", config.withdrawer);
        console2.log("NPM", config.npm);
        console2.log("UniversalRouter", config.universalRouter);
        console2.log("0xAllowanceHolder", config.zeroxAllowanceHolder);
        console2.log("TWAPSeconds", config.twapSeconds);
        console2.log("MaxTWAPTickDifference", config.maxTwapTickDifference);

        console2.log("Vault whitelist calldata: setTransformer(newAutoRange,true)");
        console2.logBytes(abi.encodeCall(ITransformerVault.setTransformer, (newAutoRange, true)));

        console2.log("Vault cleanup calldata: setTransformer(oldAutoRange,false)");
        console2.logBytes(abi.encodeCall(ITransformerVault.setTransformer, (config.oldAutoRange, false)));

        if (config.owner != tx.origin) {
            console2.log("AutoRange owner must accept ownership with calldata:");
            console2.logBytes(abi.encodeCall(IOwnable2StepLike.acceptOwnership, ()));
        }
    }

    function _envOrAddress(string memory key, address defaultValue) internal returns (address value) {
        try vm.envString(key) returns (string memory rawValue) {
            return _parseAddress(key, rawValue);
        } catch {
            return defaultValue;
        }
    }

    function _envOrUint32(string memory key, uint32 defaultValue) internal returns (uint32 value) {
        return uint32(_envOrUintBounded(key, defaultValue, type(uint32).max));
    }

    function _envOrUint16(string memory key, uint16 defaultValue) internal returns (uint16 value) {
        return uint16(_envOrUintBounded(key, defaultValue, type(uint16).max));
    }

    function _envOrUintBounded(string memory key, uint256 defaultValue, uint256 maxValue)
        internal
        returns (uint256 value)
    {
        try vm.envString(key) returns (string memory rawValue) {
            value = _parseUint(key, rawValue);
            if (value > maxValue) {
                revert InvalidUintEnv(key, rawValue);
            }
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _assertVaultNpm(address vault, address expectedNpm) internal view {
        address vaultNpm = ITransformerVault(vault).nonfungiblePositionManager();
        if (vaultNpm != expectedNpm) {
            revert InvalidVaultNpm(vaultNpm, expectedNpm);
        }
    }

    function _assertContract(address target) internal view {
        if (target.code.length == 0) {
            revert MissingContractCode(target);
        }
    }

    function _parseAddress(string memory key, string memory value) internal pure returns (address parsed) {
        bytes memory raw = bytes(value);
        if (raw.length != 42 || uint8(raw[0]) != 48 || !_isHexPrefix(raw[1])) {
            revert InvalidAddressEnv(key, value);
        }

        uint160 result;
        for (uint256 i = 2; i < raw.length; ++i) {
            result = result * 16 + uint160(_hexValue(raw[i], key, value, true));
        }
        return address(result);
    }

    function _parseUint(string memory key, string memory value) internal pure returns (uint256 parsed) {
        bytes memory raw = bytes(value);
        if (raw.length == 0) {
            revert InvalidUintEnv(key, value);
        }

        uint256 start;
        uint256 base = 10;
        if (raw.length > 2 && uint8(raw[0]) == 48 && _isHexPrefix(raw[1])) {
            start = 2;
            base = 16;
        }
        if (start == raw.length) {
            revert InvalidUintEnv(key, value);
        }

        for (uint256 i = start; i < raw.length; ++i) {
            uint8 digit;
            if (base == 16) {
                digit = _hexValue(raw[i], key, value, false);
            } else {
                if (uint8(raw[i]) < 48 || uint8(raw[i]) > 57) {
                    revert InvalidUintEnv(key, value);
                }
                digit = uint8(raw[i]) - 48;
            }
            parsed = parsed * base + digit;
        }
    }

    function _isHexPrefix(bytes1 char) internal pure returns (bool) {
        uint8 c = uint8(char);
        return c == 120 || c == 88;
    }

    function _hexValue(bytes1 char, string memory key, string memory value, bool isAddress)
        internal
        pure
        returns (uint8)
    {
        uint8 c = uint8(char);
        if (c >= 48 && c <= 57) {
            return c - 48;
        }
        if (c >= 97 && c <= 102) {
            return c - 97 + 10;
        }
        if (c >= 65 && c <= 70) {
            return c - 65 + 10;
        }
        if (isAddress) {
            revert InvalidAddressEnv(key, value);
        }
        revert InvalidUintEnv(key, value);
    }
}
