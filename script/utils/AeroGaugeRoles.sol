// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../../src/permissions/AeroGaugeRegistrationCondition.sol";

/// @dev Deployment/maintenance helpers only; not part of the lending suite.
library AeroGaugeRoles {
    bytes32 internal constant ROLE = keccak256("REVERT_AERO_REGISTER_NEW_GAUGE_V1");
    address internal constant IMPLEMENTATION = 0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5;
    address internal constant PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant INTEGRITY = 0x6a6Af4b16458Bc39817e4019fB02BD3b26d41049;
    address internal constant PACKER = 0x869718C939652084BC491fBC5ce0D3C1d5B309F0;
    address internal constant SAFE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address internal constant MANAGER = 0xeF1367c2B487233315fE14909A738C7517a41beD;

    struct Call {
        address to;
        bytes data;
    }

    function verifyDependencies() internal view {
        require(block.chainid == 8453, "Base only");
        require(
            IMPLEMENTATION.codehash == 0x471d8b3b419f1eb955230c0326c8812176df49bf3c7b414a563fda5a3c6c10b6,
            "Roles code changed"
        );
        require(
            INTEGRITY.codehash == 0xee8ec55ea4ac609a3fc768eccf3f0479631454fe0a802e4a4b8132102d10d495,
            "Integrity code changed"
        );
        require(
            PACKER.codehash == 0xc28f5fb0c8857669286d01e3df89f310d5ddfbf98205ad46d2f7d28767a76c82, "Packer code changed"
        );
        require(
            PROXY_FACTORY.codehash == 0x01623cbcf010a1c326230f1b2d5f48a66b440232ee49096102bc84967dc5f21e,
            "proxy factory code changed"
        );
    }

    function verifyInstance(address roles) internal view {
        verifyDependencies();
        // Exact runtime emitted by the pinned Zodiac ModuleProxyFactory 1.2.0.
        require(
            roles.codehash
                == keccak256(
                    abi.encodePacked(hex"363d3d373d3d3d363d73", IMPLEMENTATION, hex"5af43d82803e903d91602b57fd5bf3")
                ),
            "wrong Roles proxy"
        );
        IZodiacRoles r = IZodiacRoles(roles);
        require(r.owner() == SAFE && r.avatar() == SAFE && r.target() == SAFE, "Roles must be Safe controlled");
        require(GaugeManager(payable(MANAGER)).owner() == SAFE, "manager must be Safe owned");
    }

    function conditions(address condition) internal pure returns (IZodiacRoles.ConditionFlat[] memory c) {
        c = new IZodiacRoles.ConditionFlat[](3);
        // Calldata/Matches -> [Static/Custom(pool), Static/Pass(gauge)].
        // The custom condition validates the full calldata, including both addresses.
        c[0] = IZodiacRoles.ConditionFlat(0, 5, 5, bytes(""));
        c[1] = IZodiacRoles.ConditionFlat(0, 1, 22, abi.encodePacked(condition, bytes12(0)));
        c[2] = IZodiacRoles.ConditionFlat(0, 1, 0, bytes(""));
    }

    function setupCalls(address roles, address condition, address operator)
        internal
        view
        returns (Call[] memory calls)
    {
        verifyInstance(roles);
        require(operator != address(0) && operator != SAFE && operator.code.length == 0, "dedicated EOA required");
        require(AeroGaugeRegistrationCondition(condition).roles() == roles, "condition/roles mismatch");
        require(!IGaugeRolesSafe(SAFE).isModuleEnabled(roles), "module already enabled");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = ROLE;
        bool[] memory enabled = new bool[](1);
        enabled[0] = true;
        calls = new Call[](4);
        calls[0] = Call(roles, abi.encodeCall(IZodiacRoles.scopeTarget, (ROLE, MANAGER)));
        calls[1] = Call(
            roles,
            abi.encodeCall(
                IZodiacRoles.scopeFunction,
                (ROLE, MANAGER, GaugeManager.setGauge.selector, conditions(condition), uint8(0))
            )
        );
        calls[2] = Call(roles, abi.encodeCall(IZodiacRoles.assignRoles, (operator, keys, enabled)));
        // Enable only after all restrictions are installed. No delegatecall, multisend unwrapper or wildcard target.
        calls[3] = Call(SAFE, abi.encodeCall(IGaugeRolesSafe.enableModule, (roles)));
    }
}
