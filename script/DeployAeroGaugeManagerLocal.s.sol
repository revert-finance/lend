// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./DeployAeroGaugeManager.s.sol";
import "../src/V3Vault.sol";
import {AeroGaugeFixture} from "../test/unit/AeroGaugeManager.t.sol";
import {MockNPM, MockPool, MockSlipstreamFactory, MockERC20Token} from "../test/unit/GaugeManager.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev Broadcast-disabled local exercise of the production adapter script with an actual fresh V3Vault.
/// Uses mocks for external protocol dependencies; never point this fixture at a production network.
contract DeployAeroGaugeManagerLocal is DeployAeroGaugeManager {
    Config private localConfig;

    function setUp() public {
        require(block.chainid == 31337, "local simulation only");
        address deployer = address(0xD3E10);
        vm.startPrank(deployer);
        MockERC20Token receipt = new MockERC20Token("Receipt", "rAERO");
        MockERC20Token usdc = new MockERC20Token("USDC", "USDC");
        MockSlipstreamFactory factory = new MockSlipstreamFactory();
        MockNPM npm = new MockNPM(address(factory), address(usdc));
        MockPool pool = new MockPool(address(receipt), address(usdc), 100);
        factory.setPool(address(receipt), address(usdc), 100, address(pool));
        AeroGaugeFixture gauge = new AeroGaugeFixture(IERC721(address(npm)), address(pool), receipt);
        pool.setGauge(address(gauge));
        // This vault is only for validating manager wiring. Lending/oracle configuration is outside this fixture.
        V3Vault vault = new V3Vault(
            "Local Aero",
            "localAero",
            address(usdc),
            INonfungiblePositionManager(address(npm)),
            IInterestRateModel(address(0)),
            IV3Oracle(address(0))
        );
        vm.stopPrank();
        Config storage c = localConfig;
        c.chainId = 31337;
        c.deployer = deployer;
        c.npm = address(npm);
        c.factory = address(factory);
        c.receiptToken = address(receipt);
        c.vault = address(vault);
        c.owner = address(0xA11CE);
        c.withdrawer = address(0xB0B);
        c.pools.push(address(pool));
        c.gauges.push(address(gauge));
        c.rewardBases.push(address(usdc));
        c.rewardPools.push(address(pool));
    }

    function _loadConfig() internal view override returns (Config memory) {
        return localConfig;
    }
}
