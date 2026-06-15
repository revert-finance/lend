// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../src/interfaces/pancake/IPancakeMasterChefV3.sol";

contract PancakeMasterChefV3ForkSmokeTest is Test {
    address internal constant PANCAKE_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

    address internal constant MAINNET_MASTER_CHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant MAINNET_CAKE = 0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898;
    address internal constant BASE_MASTER_CHEF = 0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3;
    address internal constant BASE_CAKE = 0x3055913c90Fcc1A6CE9a358911721eEb942013A1;

    address internal constant ARBITRUM_MASTER_CHEF = 0x5e09ACf80C0296740eC5d6F643005a4ef8DaA694;
    address internal constant ARBITRUM_CAKE = 0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c;

    address internal constant BSC_MASTER_CHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant BSC_CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    function testMainnetDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("MAINNET_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(MAINNET_MASTER_CHEF, MAINNET_CAKE);
    }

    function testBaseDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("BASE_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(BASE_MASTER_CHEF, BASE_CAKE);
    }

    function testArbitrumDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("ARBITRUM_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(ARBITRUM_MASTER_CHEF, ARBITRUM_CAKE);
    }

    function testBscDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("BSC_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(BSC_MASTER_CHEF, BSC_CAKE);
    }

    function _deployAndAssert(address masterChef, address cake) internal {
        IPancakeMasterChefV3 chef = IPancakeMasterChefV3(masterChef);
        assertEq(chef.CAKE(), cake);
        assertEq(chef.nonfungiblePositionManager(), PANCAKE_NPM);

        PancakeMasterChefV3Staker staker =
            new PancakeMasterChefV3Staker(INonfungiblePositionManager(PANCAKE_NPM), chef, IERC20(cake));
        AutoRangeAndCompound autoRangeAndCompound = new AutoRangeAndCompound(
            INonfungiblePositionManager(PANCAKE_NPM), address(this), address(this), 60, 100, address(0), address(0)
        );

        autoRangeAndCompound.setPancakeStaker(address(staker));
        staker.setTransformer(address(autoRangeAndCompound), true);
        _configureBasePoolsIfProvided(staker);

        assertTrue(autoRangeAndCompound.pancakeStakers(address(staker)));
    }

    function _configureBasePoolsIfProvided(PancakeMasterChefV3Staker staker) internal {
        address[] memory baseTokens;
        address[] memory basePools;
        try vm.envAddress("PANCAKE_REWARD_BASE_TOKENS", ",") returns (address[] memory parsedTokens) {
            baseTokens = parsedTokens;
        } catch {
            return;
        }
        basePools = vm.envAddress("PANCAKE_REWARD_BASE_POOLS", ",");
        assertEq(baseTokens.length, basePools.length);
        for (uint256 i; i < baseTokens.length; ++i) {
            staker.setRewardBasePool(baseTokens[i], basePools[i]);
            assertEq(staker.rewardBasePools(baseTokens[i]), basePools[i]);
        }
    }
}
