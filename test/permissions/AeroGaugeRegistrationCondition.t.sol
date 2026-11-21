// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/permissions/AeroGaugeRegistrationCondition.sol";

contract AeroGaugeRegistrationConditionTest is Test {
    AeroGaugeRegistrationCondition condition;
    address constant SAFE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address constant MANAGER = 0xeF1367c2B487233315fE14909A738C7517a41beD;
    address constant FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address constant VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address constant REGISTRY = 0x7b2A2c12dC5Ea2a31455952a05031C3E4BB28F3E;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant HANDLER = 0x8C37F30F3c8fd48bEddb14086fa5148291D422C3;
    address constant ROLES = address(0x111);
    address constant POOL = address(0x222);
    address constant GAUGE = address(0x333);

    function _mock(address target, string memory signature, bytes memory result) internal {
        vm.etch(target, hex"00");
        vm.mockCall(target, abi.encodeWithSignature(signature), result);
    }

    function setUp() public {
        vm.chainId(8453);
        _mock(ROLES, "owner()", abi.encode(SAFE));
        _mock(ROLES, "avatar()", abi.encode(SAFE));
        _mock(ROLES, "target()", abi.encode(SAFE));
        _mock(MANAGER, "owner()", abi.encode(SAFE));
        _mock(MANAGER, "factory()", abi.encode(FACTORY));
        _mock(MANAGER, "nonfungiblePositionManager()", abi.encode(NPM));
        _mock(MANAGER, "aeroToken()", abi.encode(AERO));
        _mock(MANAGER, "rootEmissionsHandler()", abi.encode(HANDLER));
        _mock(MANAGER, "poolToGauge(address)", abi.encode(address(0)));
        _mock(POOL, "token0()", abi.encode(address(10)));
        _mock(POOL, "token1()", abi.encode(address(11)));
        _mock(POOL, "tickSpacing()", abi.encode(int24(10)));
        _mock(POOL, "gauge()", abi.encode(GAUGE));
        _mock(FACTORY, "getPool(address,address,int24)", abi.encode(POOL));
        _mock(FACTORY, "voter()", abi.encode(VOTER));
        _mock(FACTORY, "factoryRegistry()", abi.encode(REGISTRY));
        _mock(REGISTRY, "isTargetFactoryApproved(address)", abi.encode(true));
        _mock(REGISTRY, "targetFactoryToGaugeFactory(address)", abi.encode(GAUGE_FACTORY));
        _mock(REGISTRY, "targetToGauge(address)", abi.encode(GAUGE));
        _mock(GAUGE, "pool()", abi.encode(POOL));
        _mock(GAUGE, "nft()", abi.encode(NPM));
        _mock(GAUGE, "gaugeFactory()", abi.encode(GAUGE_FACTORY));
        _mock(GAUGE, "voter()", abi.encode(VOTER));
        _mock(VOTER, "isActivated(address)", abi.encode(true));
        _mock(VOTER, "RECEIPT_TOKEN()", abi.encode(address(12)));
        _mock(VOTER, "EMISSIONS_HANDLER()", abi.encode(HANDLER));
        _mock(HANDLER, "LEAF_VOTER()", abi.encode(VOTER));
        _mock(HANDLER, "pendingRedeems(address)", abi.encode(uint256(0)));
        _mock(VOTER, "ORCHESTRATOR()", abi.encode(address(13)));
        _mock(address(13), "adapter()", abi.encode(address(14)));
        _mock(address(13), "ROOT_CHAIN_ID()", abi.encode(uint256(8453)));
        _mock(address(14), "ROOT_MESSAGE_ORCHESTRATOR()", abi.encode(address(15)));
        _mock(address(14), "REMOTE_CHAIN_ID()", abi.encode(uint256(8453)));
        _mock(address(14), "LEAF_MESSAGE_ORCHESTRATOR()", abi.encode(address(13)));
        _mock(address(15), "VOTER()", abi.encode(address(16)));
        _mock(address(16), "ORCHESTRATOR()", abi.encode(address(15)));
        _mock(address(16), "TOKEN()", abi.encode(AERO));
        condition = new AeroGaugeRegistrationCondition(ROLES);
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeCall(GaugeManager.setGauge, (POOL, GAUGE));
    }

    function _check(bytes memory data) internal returns (bool ok) {
        vm.prank(ROLES);
        (ok,) = condition.check(MANAGER, 0, data, 0, 4, 32, bytes12(0));
    }

    function testOfficialNewGaugeAccepted() public {
        assertTrue(_check(_data()));
    }

    function testDoesNotMutateRegistration() public {
        _check(_data());
        assertEq(GaugeManager(payable(MANAGER)).poolToGauge(POOL), address(0));
    }

    function testExistingMappingCannotBeOverwrittenOrRepeated() public {
        _mock(MANAGER, "poolToGauge(address)", abi.encode(GAUGE));
        vm.expectRevert(AeroGaugeRegistrationCondition.AlreadyRegistered.selector);
        _check(_data());
    }

    function testForgedPoolCannotSelfAttest() public {
        _mock(FACTORY, "getPool(address,address,int24)", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testGaugeMustBeInPinnedRegistry() public {
        _mock(REGISTRY, "targetToGauge(address)", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testPoolMustNameGauge() public {
        _mock(POOL, "gauge()", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testFakeVoterRejected() public {
        _mock(GAUGE, "voter()", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testInactiveGaugeRejected() public {
        _mock(VOTER, "isActivated(address)", abi.encode(false));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testRevokedFactoryRejected() public {
        _mock(REGISTRY, "isTargetFactoryApproved(address)", abi.encode(false));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testWrongNpmRejected() public {
        _mock(GAUGE, "nft()", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testWrongGaugeFactoryRejected() public {
        _mock(GAUGE, "gaugeFactory()", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidRegistration.selector);
        _check(_data());
    }

    function testWrongRewardTokenRejected() public {
        _mock(address(16), "TOKEN()", abi.encode(address(99)));
        vm.expectRevert(AeroRewardDelivery.UnsupportedRewardDelivery.selector);
        _check(_data());
    }

    function testDependencyReadFailureDeniesRegistration() public {
        vm.mockCall(FACTORY, abi.encodeWithSignature("getPool(address,address,int24)"), hex"01");
        vm.expectRevert();
        _check(_data());
    }

    function testWrongChainRejected() public {
        vm.chainId(1);
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidDeployment.selector);
        _check(_data());
    }

    function testWrongSafeConfigurationRejectedAtConstruction() public {
        _mock(ROLES, "target()", abi.encode(address(99)));
        vm.expectRevert(AeroGaugeRegistrationCondition.InvalidDeployment.selector);
        new AeroGaugeRegistrationCondition(ROLES);
    }

    function testWrongCallerDenied() public {
        (bool ok,) = condition.check(MANAGER, 0, _data(), 0, 4, 32, bytes12(0));
        assertFalse(ok);
    }

    function testWrongSelectorDenied() public {
        assertFalse(_check(abi.encodeWithSignature("setRewardBasePool(address,address)", POOL, GAUGE)));
    }

    function testTrailingCalldataDenied() public {
        assertFalse(_check(abi.encodePacked(_data(), bytes1(0))));
    }

    function testFuzzInvalidEnvelopeDenied(
        address to,
        uint256 value,
        uint8 op,
        uint256 location,
        uint256 size,
        bytes12 extra
    ) public {
        vm.assume(to != MANAGER || value != 0 || op != 0 || location != 4 || size != 32 || extra != bytes12(0));
        vm.prank(ROLES);
        (bool ok,) = condition.check(to, value, _data(), op, location, size, extra);
        assertFalse(ok);
    }

    function testFuzzWrongCalldataLengthDenied(bytes memory data) public {
        vm.assume(data.length != 68);
        assertFalse(_check(data));
    }
}
