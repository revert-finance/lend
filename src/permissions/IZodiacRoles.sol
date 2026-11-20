// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev ABI subset pinned to Zodiac Roles 2.1.1. Enum ABI values are uint8.
/// Source: zodiaceco/zodiac b7988c0e352c8e409145b76d193ba67a6f2e44d1.
interface IZodiacRoles {
    struct ConditionFlat {
        uint8 parent;
        uint8 paramType;
        uint8 operator;
        bytes compValue;
    }

    function setUp(bytes calldata params) external;
    function owner() external view returns (address);
    function avatar() external view returns (address);
    function target() external view returns (address);
    function assignRoles(address member, bytes32[] calldata keys, bool[] calldata enabled) external;
    function scopeTarget(bytes32 key, address to) external;
    function scopeFunction(bytes32 key, address to, bytes4 selector, ConditionFlat[] calldata conditions, uint8 options)
        external;
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 key,
        bool revertOnFailure
    ) external returns (bool);
}

interface IZodiacProxyFactory {
    function deployModule(address implementation, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address);
}

interface IGaugeRolesSafe {
    function enableModule(address module) external;
    function disableModule(address previousModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
}
