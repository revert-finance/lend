// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../src/transformers/AutoRangeAndCompound.sol";
import "../../src/interfaces/IVault.sol";

contract MockPositionManagerOwnerOnly {
    address public immutable weth9;
    address public immutable factory;

    mapping(uint256 => address) public owners;

    constructor(address _weth9, address _factory) {
        weth9 = _weth9;
        factory = _factory;
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function WETH9() external view returns (address) {
        return weth9;
    }
}

contract MockVaultRewardCapture {
    uint256 public lastTokenId;
    address public lastTransformer;
    bytes public lastData;

    uint256 public lastMinAeroReward;
    uint256 public lastAeroSplitBps;
    uint256 public lastDeadline;

    function transformWithRewardCompound(
        uint256 tokenId,
        address transformer,
        bytes calldata data,
        IVault.RewardCompoundParams calldata rewardParams
    ) external returns (uint256 newTokenId) {
        lastTokenId = tokenId;
        lastTransformer = transformer;
        lastData = data;
        lastMinAeroReward = rewardParams.minAeroReward;
        lastAeroSplitBps = rewardParams.aeroSplitBps;
        lastDeadline = rewardParams.deadline;
        return tokenId;
    }
}

contract AutoRangeAndCompoundRewardCompoundConfigTest is Test {
    uint256 internal constant TOKEN_ID = 123;
    address internal constant OPERATOR = address(0xAA11);
    address internal constant WITHDRAWER = address(0xBB22);
    address internal constant USER = address(0xCC33);

    MockPositionManagerOwnerOnly internal mockNpm;
    MockVaultRewardCapture internal mockVault;
    AutoRangeAndCompound internal autoRange;

    function setUp() external {
        mockNpm = new MockPositionManagerOwnerOnly(address(0x1111), address(0x2222));
        mockVault = new MockVaultRewardCapture();

        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(mockNpm)),
            OPERATOR,
            WITHDRAWER,
            60,
            100,
            address(0),
            address(0)
        );
        autoRange.setVault(address(mockVault));

        mockNpm.setOwner(TOKEN_ID, USER);
    }

    function testRewardCompoundParamsArePassedThrough() external {
        vm.prank(USER);
        autoRange.configToken(
            TOKEN_ID,
            address(0),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 11,
                autoCompoundMin1: 22,
                autoCompoundRewardMin: 33
            })
        );

        IVault.RewardCompoundParams memory rewardParams = IVault.RewardCompoundParams({
            minAeroReward: 3,
            aeroSplitBps: 4_000,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: TOKEN_ID,
                swap0To1: false,
                amountIn: 0,
                deadline: block.timestamp + 1 hours
            }),
            address(mockVault),
            rewardParams
        );

        assertEq(mockVault.lastTokenId(), TOKEN_ID);
        assertEq(mockVault.lastTransformer(), address(autoRange));
        assertEq(mockVault.lastMinAeroReward(), 33);
        assertEq(mockVault.lastAeroSplitBps(), 4_000);
        assertEq(mockVault.lastDeadline(), block.timestamp + 1 hours);
    }

    function testRewardCompoundParamsUseConfiguredMinAeroRewardEvenWhenCallerProvidesHigherValue() external {
        vm.prank(USER);
        autoRange.configToken(
            TOKEN_ID,
            address(0),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 11,
                autoCompoundMin1: 22,
                autoCompoundRewardMin: 33
            })
        );

        IVault.RewardCompoundParams memory rewardParams = IVault.RewardCompoundParams({
            minAeroReward: 333,
            aeroSplitBps: 5_000,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: TOKEN_ID,
                swap0To1: false,
                amountIn: 0,
                deadline: block.timestamp + 1 hours
            }),
            address(mockVault),
            rewardParams
        );

        assertEq(mockVault.lastMinAeroReward(), 33);
        assertEq(mockVault.lastAeroSplitBps(), 5_000);
    }
}
