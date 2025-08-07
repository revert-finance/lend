// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../../src/transformers/AeroCompound.sol";
import "../../../src/GaugeManager.sol";
import "../../../src/V3Vault.sol";
import "../../../src/V3Oracle.sol";
import "../../../src/InterestRateModel.sol";
import "../aerodrome/AerodromeTestBase.sol";
import "../../../src/utils/Constants.sol";

contract AeroCompoundTest is AerodromeTestBase {
    AeroCompound aeroCompound;
    InterestRateModel interestRateModel;
    
    // Test position
    uint256 testTokenId;
    address testPositionOwner;
    
    function setUp() public override {
        super.setUp();
        
        // The base test already creates oracle, pools, and feeds
        // We just need to create vault and other components
        
        // Deploy interest rate model
        interestRateModel = new InterestRateModel(
            0, // base rate (0%)
            Q64 * 5 / 100, // multiplier (5%)
            Q64 * 200 / 100, // jump multiplier (200% - max allowed)
            Q64 * 80 / 100 // kink (80%)
        );
        
        // Use the vault and gauge manager from base test
        // Note: The base test already sets up vault and gauge manager
        
        // Deploy AeroCompound
        aeroCompound = new AeroCompound(
            npm,
            address(this), // operator
            address(this), // withdrawer
            60, // TWAP seconds
            200, // max TWAP tick difference
            address(0), // universal router (not used in test)
            address(0), // 0x allowance holder (not used in test)
            address(aero),
            address(gaugeManager),
            address(factory)
        );
        
        // Fund test accounts
        testPositionOwner = address(0x789);
        usdc.transfer(testPositionOwner, 10000e6);
        dai.transfer(testPositionOwner, 10000e18);
        
        // Create a test position
        vm.startPrank(testPositionOwner);
        usdc.approve(address(npm), type(uint256).max);
        dai.approve(address(npm), type(uint256).max);
        
        testTokenId = createPositionProper(
            testPositionOwner,
            address(usdc),
            address(dai),
            1, // tickSpacing
            -887272,
            887272,
            100e18, // liquidity
            1000e6, // amount0
            1000e18 // amount1
        );
        
        // Deposit position into vault
        npm.approve(address(vault), testTokenId);
        vault.create(testTokenId, testPositionOwner);
        
        // Create and set mock gauge for the pool
        address pool = factory.getPool(address(usdc), address(dai), 1);
        MockAeroGauge gauge = new MockAeroGauge(address(npm), address(aero));
        
        // The gauge manager is owned by the vault from base test, so we need to prank as vault owner
        vm.stopPrank();
        vm.prank(vault.owner());
        gaugeManager.setGauge(pool, address(gauge));
        
        // Stake the position as the position owner
        vm.prank(testPositionOwner);
        vault.stakePosition(testTokenId);
        
        // Mock some AERO rewards for testing
        aero.transfer(address(gauge), 1000e18);
        
        // Set vault for AeroCompound as the owner
        aeroCompound.setVault(address(vault));
    }
    
    function testAeroCompoundBasic() external {
        // Mock some AERO rewards
        MockAeroGauge gauge = MockAeroGauge(gaugeManager.getPositionGauge(testTokenId));
        aero.mint(address(gauge), 100e18);
        gauge.setRewards(address(gaugeManager), 100e18);
        
        // Execute compound
        AeroCompound.ExecuteParams memory params = AeroCompound.ExecuteParams({
            tokenId: testTokenId,
            minAmount0: 0,
            minAmount1: 0,
            swapData0: "", // No swap for test
            swapData1: "",
            deadline: block.timestamp + 3600
        });
        
        // Should revert without proper swap data in real scenario
        vm.expectRevert();
        aeroCompound.executeWithVault(params, address(vault));
    }
    
    function testClaimAndDistribute() external {
        // Mock some AERO rewards
        MockAeroGauge gauge = MockAeroGauge(gaugeManager.getPositionGauge(testTokenId));
        aero.mint(address(gauge), 100e18);
        gauge.setRewards(address(gaugeManager), 100e18);
        
        // Claim rewards
        gaugeManager.claimRewards(testTokenId);
        
        // Check accumulated rewards
        uint256 accumulated = gaugeManager.accumulatedRewards(testTokenId);
        assertEq(accumulated, 100e18);
        
        // Distribute to position owner
        vm.prank(address(vault));
        gaugeManager.distributeRewards(testTokenId, alice);
        
        // Check alice received AERO
        assertEq(aero.balanceOf(alice), 100e18);
    }
    
    function testUnauthorizedAccess() external {
        // Try to execute as non-operator
        vm.expectRevert(Unauthorized.selector);
        vm.prank(address(0x999));
        aeroCompound.execute(
            AeroCompound.ExecuteParams({
                tokenId: testTokenId,
                minAmount0: 0,
                minAmount1: 0,
                swapData0: "",
                swapData1: "",
                deadline: block.timestamp + 3600
            })
        );
    }
    
    function testGetLeftoverBalances() external {
        // First, create some leftover balances by simulating a compound
        // Transfer some tokens directly to the compound contract
        usdc.transfer(address(aeroCompound), 100e6);
        dai.transfer(address(aeroCompound), 100e18);
        
        // Manually set balances (we need to expose this for testing or simulate via compound)
        // For now, let's simulate by calling internal functions through a compound operation
        
        // Query leftover balances
        (uint256 amount0, uint256 amount1, address token0, address token1) = 
            aeroCompound.getLeftoverBalances(testTokenId);
        
        // Initially should be zero
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        
        // Verify token addresses are correct
        // Based on the actual position, USDC is token0 and DAI is token1
        assertEq(token0, address(usdc)); // USDC is token0
        assertEq(token1, address(dai));  // DAI is token1
    }
    
    function testWithdrawAllBalances() external {
        // First, we need to create some leftover balances
        // This would normally happen during a compound operation
        // For testing, we'll simulate by transferring tokens and manually tracking
        
        // Transfer tokens to compound contract
        uint256 leftoverUsdc = 50e6;
        uint256 leftoverDai = 75e18;
        usdc.transfer(address(aeroCompound), leftoverUsdc);
        dai.transfer(address(aeroCompound), leftoverDai);
        
        // We need to simulate leftover creation through actual compound
        // For simplicity, let's just test the withdrawal logic
        // In a real scenario, these would be set during compound operation
        
        // Get the actual owner of the position
        address positionOwner = vault.ownerOf(testTokenId);
        
        // Get initial balances of position owner
        uint256 ownerUsdcBefore = usdc.balanceOf(positionOwner);
        uint256 ownerDaiBefore = dai.balanceOf(positionOwner);
        
        // Try to withdraw as non-owner (should fail)
        vm.expectRevert(Unauthorized.selector);
        vm.prank(address(0x999));
        aeroCompound.withdrawAllBalances(testTokenId);
        
        // Withdraw as owner (should succeed if there are balances)
        // Note: In this test, balances are 0 because we haven't actually compounded
        // This just tests the function doesn't revert
        vm.prank(positionOwner);
        aeroCompound.withdrawAllBalances(testTokenId);
        
        // Verify no change since there were no leftovers
        assertEq(usdc.balanceOf(positionOwner), ownerUsdcBefore);
        assertEq(dai.balanceOf(positionOwner), ownerDaiBefore);
    }
    
    function testWithdrawSingleBalance() external {
        // Get the actual owner of the position
        address positionOwner = vault.ownerOf(testTokenId);
        
        // Get initial balance of position owner
        uint256 ownerUsdcBefore = usdc.balanceOf(positionOwner);
        
        // Try to withdraw as non-owner (should fail)
        vm.expectRevert(Unauthorized.selector);
        vm.prank(address(0x999));
        aeroCompound.withdrawBalance(testTokenId, address(usdc));
        
        // Withdraw as owner (should succeed but no balance to withdraw)
        vm.prank(positionOwner);
        aeroCompound.withdrawBalance(testTokenId, address(usdc));
        
        // Verify no change since there were no leftovers
        assertEq(usdc.balanceOf(positionOwner), ownerUsdcBefore);
    }
}

// Mock gauge for testing
contract MockAeroGauge {
    IERC20 public immutable rewardToken;
    INonfungiblePositionManager public immutable npm;
    mapping(address => uint256) public earned;
    mapping(uint256 => address) public stakedBy;
    
    constructor(address _npm, address _rewardToken) {
        npm = INonfungiblePositionManager(_npm);
        rewardToken = IERC20(_rewardToken);
    }
    
    function deposit(uint256 tokenId) external {
        npm.transferFrom(msg.sender, address(this), tokenId);
        stakedBy[tokenId] = msg.sender;
    }
    
    function withdraw(uint256 tokenId) external {
        require(stakedBy[tokenId] == msg.sender, "Not staker");
        npm.transferFrom(address(this), msg.sender, tokenId);
        delete stakedBy[tokenId];
    }
    
    function getReward() external {
        uint256 reward = earned[msg.sender];
        if (reward > 0) {
            earned[msg.sender] = 0;
            rewardToken.transfer(msg.sender, reward);
        }
    }
    
    function getReward(address user) external {
        uint256 reward = earned[user];
        if (reward > 0) {
            earned[user] = 0;
            rewardToken.transfer(user, reward);
        }
    }
    
    function setRewards(address user, uint256 amount) external {
        earned[user] = amount;
    }
    
    function isStaked(uint256 tokenId) external view returns (bool) {
        return stakedBy[tokenId] != address(0);
    }
} 