// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../GaugeManager.sol";
import "./IZodiacRoles.sol";

interface IAeroRegistrationFactory {
    function getPool(address token0, address token1, int24 spacing) external view returns (address);
    function voter() external view returns (address);
    function factoryRegistry() external view returns (address);
}

interface IAeroRegistrationRegistry {
    function targetToGauge(address pool) external view returns (address);
    function targetFactoryToGaugeFactory(address factory) external view returns (address);
    function isTargetFactoryApproved(address factory) external view returns (bool);
}

interface IAeroRegistrationVoter {
    function isActivated(address gauge) external view returns (bool);
}

/// @notice Zodiac condition for first-time gauge registrations in the current Base Aero deployment.
/// @dev No setters, custody, or execution authority. The Safe owns the manager and Roles instance.
/// Official registries are trust anchors; a pool/gauge merely reporting the right addresses is insufficient.
contract AeroGaugeRegistrationCondition {
    address public constant SAFE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address public constant MANAGER = 0xeF1367c2B487233315fE14909A738C7517a41beD;
    address public constant FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address public constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address public constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address public constant VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address public constant REGISTRY = 0x7b2A2c12dC5Ea2a31455952a05031C3E4BB28F3E;
    address public constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address public constant ROOT_HANDLER = 0x8C37F30F3c8fd48bEddb14086fa5148291D422C3;
    address public immutable roles;

    error InvalidRegistration();
    error AlreadyRegistered();
    error InvalidDeployment();

    constructor(address roles_) {
        roles = roles_;
        GaugeManager manager = GaugeManager(payable(MANAGER));
        IZodiacRoles r = IZodiacRoles(roles_);
        if (
            block.chainid != 8453 || r.owner() != SAFE || r.avatar() != SAFE || r.target() != SAFE
                || manager.owner() != SAFE || manager.factory() != FACTORY
                || address(manager.nonfungiblePositionManager()) != NPM || address(manager.aeroToken()) != AERO
                || manager.rootEmissionsHandler() != ROOT_HANDLER
        ) revert InvalidDeployment();
    }

    /// @dev Custom condition on the first static parameter of setGauge(address,address).
    /// Incorrect envelopes return false. Bad registry/dependency reads revert, also denying execution.
    function check(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 location,
        uint256 size,
        bytes12 extra
    ) external view returns (bool success, bytes32 reason) {
        if (
            msg.sender != roles || to != MANAGER || value != 0 || operation != 0 || data.length != 68 || location != 4
                || size != 32 || extra != bytes12(0)
        ) return (false, bytes32("INVALID_CALL"));
        if (bytes4(data[:4]) != GaugeManager.setGauge.selector) return (false, bytes32("INVALID_SELECTOR"));
        (address pool, address gauge) = abi.decode(data[4:], (address, address));
        validate(pool, gauge);
        return (true, bytes32(0));
    }

    /// @notice Read-only preflight; the same checks run again during Zodiac execution.
    function validate(address pool, address gauge) public view {
        if (block.chainid != 8453) revert InvalidDeployment();
        if (GaugeManager(payable(MANAGER)).poolToGauge(pool) != address(0)) revert AlreadyRegistered();
        if (pool.code.length == 0 || gauge.code.length == 0) revert InvalidRegistration();
        IAerodromeSlipstreamPool p = IAerodromeSlipstreamPool(pool);
        IAeroRegistrationFactory factory = IAeroRegistrationFactory(FACTORY);
        IAeroRegistrationRegistry registry = IAeroRegistrationRegistry(REGISTRY);
        // Query the pinned factory/registry, never a factory/voter nominated by the caller.
        if (
            factory.getPool(p.token0(), p.token1(), p.tickSpacing()) != pool || factory.voter() != VOTER
                || factory.factoryRegistry() != REGISTRY || !registry.isTargetFactoryApproved(FACTORY)
                || registry.targetFactoryToGaugeFactory(FACTORY) != GAUGE_FACTORY
                || registry.targetToGauge(pool) != gauge || p.gauge() != gauge
        ) revert InvalidRegistration();
        IAeroGauge g = IAeroGauge(gauge);
        if (
            g.pool() != pool || g.nft() != NPM || g.gaugeFactory() != GAUGE_FACTORY || g.voter() != VOTER
                || !IAeroRegistrationVoter(VOTER).isActivated(gauge)
                || AeroRewardDelivery.validate(gauge, AERO) != ROOT_HANDLER
        ) revert InvalidRegistration();
    }
}
