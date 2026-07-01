// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/transformers/AutoRangeAndCompound.sol";
import "../src/interfaces/aerodrome/IAerodromeNonfungiblePositionManager.sol";

interface IAerodromeTransformerVault {
    function owner() external view returns (address);
    function nonfungiblePositionManager() external view returns (address);
    function setTransformer(address transformer, bool active) external;
}

interface IOwnable2StepLike {
    function acceptOwnership() external;
}

contract DeployAerodromeAutoRangeFix is Script {
    error UnsupportedChain(uint256 chainId);
    error MissingContractCode(address target);
    error InvalidAddressEnv(string key, string value);
    error InvalidUintEnv(string key, string value);
    error InvalidTwapConfig(uint32 twapSeconds, uint16 maxTwapTickDifference);
    error InvalidVaultNpm(address vaultNpm, address expectedNpm);

    uint256 internal constant BASE_CHAIN_ID = 8453;

    address internal constant AERODROME_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant AERODROME_SWAP_ROUTER = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    address internal constant BASE_MULTISIG = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address internal constant MULTICHAIN_OPERATOR = 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF;
    address internal constant MULTICHAIN_WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;

    struct DeployConfig {
        address vault;
        address oldAutoRange;
        address owner;
        address operator;
        address withdrawer;
        address router;
        address zeroxAllowanceHolder;
        uint32 twapSeconds;
        uint16 maxTwapTickDifference;
    }

    function run() external returns (AutoRangeAndCompound autoRange) {
        DeployConfig memory config = _loadConfig();

        _assertContract(AERODROME_NPM);
        _assertContract(config.vault);
        _assertContract(config.oldAutoRange);
        _assertContract(config.router);
        _assertContract(config.zeroxAllowanceHolder);
        _assertVaultNpm(config.vault, AERODROME_NPM);

        vm.startBroadcast();

        autoRange = new AutoRangeAndCompound(
            IAerodromeNonfungiblePositionManager(AERODROME_NPM),
            config.operator,
            config.withdrawer,
            config.twapSeconds,
            config.maxTwapTickDifference,
            config.router,
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
        if (block.chainid != BASE_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }

        config.vault = vm.envAddress("VAULT");
        config.oldAutoRange = vm.envAddress("OLD_AUTO_RANGE");
        config.owner = _envOrAddress("OWNER", BASE_MULTISIG);
        config.operator = _envOrAddress("OPERATOR", address(0));
        config.withdrawer = _envOrAddress("WITHDRAWER", MULTICHAIN_WITHDRAWER);
        config.router = _envOrAddress("AERODROME_SWAP_ROUTER", AERODROME_SWAP_ROUTER);
        config.zeroxAllowanceHolder = _envOrAddress("ZEROX_ALLOWANCE_HOLDER", ZEROX_ALLOWANCE_HOLDER);
        config.twapSeconds = _envOrUint32("TWAP_SECONDS", 60);
        config.maxTwapTickDifference = _envOrUint16("MAX_TWAP_TICK_DIFFERENCE", 100);

        if (config.twapSeconds < 60 || config.maxTwapTickDifference > 200) {
            revert InvalidTwapConfig(config.twapSeconds, config.maxTwapTickDifference);
        }
    }

    function _logDeployment(DeployConfig memory config, address newAutoRange) internal view {
        address vaultOwner = IAerodromeTransformerVault(config.vault).owner();

        console2.log("Network", "base-aerodrome");
        console2.log("NewAutoRangeAndCompound", newAutoRange);
        console2.log("OldAutoRangeAndCompound", config.oldAutoRange);
        console2.log("Vault", config.vault);
        console2.log("VaultOwner", vaultOwner);
        console2.log("AutoRangeOwner", config.owner);
        console2.log("Operator", config.operator);
        console2.log("KnownMultichainOperator", MULTICHAIN_OPERATOR);
        console2.log("Withdrawer", config.withdrawer);
        console2.log("AerodromeNPM", AERODROME_NPM);
        console2.log("AerodromeSwapRouter", config.router);
        console2.log("0xAllowanceHolder", config.zeroxAllowanceHolder);
        console2.log("TWAPSeconds", config.twapSeconds);
        console2.log("MaxTWAPTickDifference", config.maxTwapTickDifference);

        console2.log("Vault whitelist calldata: setTransformer(newAutoRange,true)");
        console2.logBytes(abi.encodeCall(IAerodromeTransformerVault.setTransformer, (newAutoRange, true)));

        console2.log("Vault cleanup calldata: setTransformer(oldAutoRange,false)");
        console2.logBytes(abi.encodeCall(IAerodromeTransformerVault.setTransformer, (config.oldAutoRange, false)));

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
        address vaultNpm = IAerodromeTransformerVault(vault).nonfungiblePositionManager();
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
