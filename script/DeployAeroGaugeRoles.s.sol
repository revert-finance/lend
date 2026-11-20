// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "./utils/AeroGaugeRoles.sol";
import "./SyncAeroGauges.s.sol";

/// @notice Deploys an inactive Roles instance and validator. Does NOT enable the module or grant permissions.
contract DeployAeroGaugeRoles is Script {
    function run() external returns (address roles, address condition) {
        address deployer = vm.envAddress("AERO_GAUGE_DEPLOYER");
        address operator = vm.envAddress("AERO_GAUGE_OPERATOR");
        uint256 salt = vm.envUint("AERO_GAUGE_ROLES_SALT");
        require(operator != deployer, "use a dedicated automation account");
        require(
            operator != address(0) && operator != AeroGaugeRoles.SAFE && operator.code.length == 0,
            "dedicated EOA required"
        );
        AeroGaugeRoles.verifyDependencies();
        bytes memory init = abi.encodeCall(
            IZodiacRoles.setUp, (abi.encode(AeroGaugeRoles.SAFE, AeroGaugeRoles.SAFE, AeroGaugeRoles.SAFE))
        );
        vm.startBroadcast(deployer);
        // Factory creates AND initializes in one transaction: no uninitialized proxy to front-run.
        roles =
            IZodiacProxyFactory(AeroGaugeRoles.PROXY_FACTORY).deployModule(AeroGaugeRoles.IMPLEMENTATION, init, salt);
        condition = address(new AeroGaugeRegistrationCondition(roles));
        vm.stopBroadcast();
        _writeSetup(roles, condition, operator);
        console2.log("ROLES", roles);
        console2.log("CONDITION", condition);
        console2.log("OPERATOR", operator);
        console2.log("Module remains disabled until the Safe executes setup.json");
    }

    function _writeSetup(address roles, address condition, address operator) internal {
        AeroGaugeRoles.Call[] memory calls = AeroGaugeRoles.setupCalls(roles, condition, operator);
        string memory txs;
        for (uint256 i; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '"}'
            );
        }
        string memory dir = string.concat("gauge-sync/roles-", vm.toString(roles));
        IAeroSyncFiles files = IAeroSyncFiles(address(vm));
        files.createDir(dir, true);
        files.writeJson(
            string.concat(
                '{"version":"1.0","chainId":"8453","createdAt":',
                vm.toString(block.timestamp * 1000),
                ',"meta":{"name":"Enable restricted Aero gauge registration","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
                vm.toString(AeroGaugeRoles.SAFE),
                '"},"transactions":[',
                txs,
                "]}"
            ),
            string.concat(dir, "/setup.json")
        );
        files.writeJson(
            string.concat(
                '{"roles":"',
                vm.toString(roles),
                '","condition":"',
                vm.toString(condition),
                '","operator":"',
                vm.toString(operator),
                '","roleKey":"',
                vm.toString(AeroGaugeRoles.ROLE),
                '"}'
            ),
            string.concat(dir, "/deployment.json")
        );
        console2.log("SAFE_SETUP", string.concat(dir, "/setup.json"));
    }
}
