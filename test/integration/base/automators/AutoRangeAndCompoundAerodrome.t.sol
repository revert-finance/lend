// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../../src/utils/Constants.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract AutoRangeAndCompoundAerodromeTest is Test, Constants {
    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    address internal constant UNIVERSAL_ROUTER = 0x198EF79F1F515F02dFE9e3115eD9fC07183f02fC;

    address internal constant OPERATOR_ACCOUNT = address(0x1111);
    address internal constant WITHDRAWER_ACCOUNT = address(0x2222);
    address internal constant POSITION_OWNER = address(0x3333);
    uint256 internal constant MOCK_TOKEN_ID = 123_456;

    AutoRangeAndCompound internal autoRange;
    uint256 internal baseFork;

    function setUp() external {
        string memory baseRpc;
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            baseRpc = url;
        } catch {
            baseRpc = "https://mainnet.base.org";
        }
        baseFork = vm.createFork(baseRpc);
        vm.selectFork(baseFork);

        autoRange = new AutoRangeAndCompound(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, UNIVERSAL_ROUTER, address(0));
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = autoRange.maxTWAPTickDifference();
        autoRange.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoRange.TWAPSeconds(), 120);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setTWAPConfig(maxTWAPTickDifference, 30);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 twapSeconds = autoRange.TWAPSeconds();
        autoRange.setTWAPConfig(5, twapSeconds);
        assertEq(autoRange.maxTWAPTickDifference(), 5);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setTWAPConfig(600, twapSeconds);
    }

    function testSetOperator() external {
        address newOperator = address(0x4444);
        assertFalse(autoRange.operators(newOperator));
        autoRange.setOperator(newOperator, true);
        assertTrue(autoRange.operators(newOperator));
    }

    function testUnauthorizedSetConfig() external {
        _mockNpmOwner(MOCK_TOKEN_ID, POSITION_OWNER);

        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoRange.configToken(MOCK_TOKEN_ID, address(0), config);
    }

    function testResetConfig() external {
        _mockNpmOwner(MOCK_TOKEN_ID, POSITION_OWNER);

        AutoRangeAndCompound.PositionConfig memory config = _defaultConfig();
        vm.prank(POSITION_OWNER);
        autoRange.configToken(MOCK_TOKEN_ID, address(0), config);

        (int32 lowerTickLimit,,,,,,,,,,,) = autoRange.positionConfigs(MOCK_TOKEN_ID);
        assertEq(lowerTickLimit, config.lowerTickLimit);

        AutoRangeAndCompound.PositionConfig memory cleared;
        vm.prank(POSITION_OWNER);
        autoRange.configToken(MOCK_TOKEN_ID, address(0), cleared);

        (
            int32 cLowerTickLimit,
            int32 cUpperTickLimit,
            int32 cLowerTickDelta,
            int32 cUpperTickDelta,
            uint64 cToken0SlippageX64,
            uint64 cToken1SlippageX64,
            bool cOnlyFees,
            bool cAutoCompound,
            uint64 cMaxRewardX64,
            uint128 cAutoCompoundMin0,
            uint128 cAutoCompoundMin1,
            uint128 cAutoCompoundRewardMin
        ) = autoRange.positionConfigs(MOCK_TOKEN_ID);
        assertEq(cLowerTickLimit, 0);
        assertEq(cUpperTickLimit, 0);
        assertEq(cLowerTickDelta, 0);
        assertEq(cUpperTickDelta, 0);
        assertEq(cToken0SlippageX64, 0);
        assertEq(cToken1SlippageX64, 0);
        assertFalse(cOnlyFees);
        assertFalse(cAutoCompound);
        assertEq(cMaxRewardX64, 0);
        assertEq(cAutoCompoundMin0, 0);
        assertEq(cAutoCompoundMin1, 0);
        assertEq(cAutoCompoundRewardMin, 0);
    }

    function testBasicConfiguration() external {
        assertEq(autoRange.TWAPSeconds(), 60);
        assertEq(autoRange.maxTWAPTickDifference(), 100);
        assertTrue(autoRange.operators(OPERATOR_ACCOUNT));
        assertEq(autoRange.withdrawer(), WITHDRAWER_ACCOUNT);
    }

    function _defaultConfig() internal pure returns (AutoRangeAndCompound.PositionConfig memory config) {
        config = AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: -2000,
            upperTickLimit: 2000,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageX64: uint64(Q64 / 100),
            token1SlippageX64: uint64(Q64 / 100),
            onlyFees: false,
            autoCompound: true,
            maxRewardX64: uint64(Q64 / 400),
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });
    }

    function _mockNpmOwner(uint256 tokenId, address owner) internal {
        vm.mockCall(address(NPM), abi.encodeWithSignature("ownerOf(uint256)", tokenId), abi.encode(owner));
    }
}
