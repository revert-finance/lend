// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/PancakeMasterChefV3AutoCompound.sol";
import "../../../src/interfaces/pancake/IPancakeMasterChefV3.sol";

contract PancakeMasterChefV3ForkSmokeTest is Test {
    address internal constant PANCAKE_NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

    address internal constant MAINNET_MASTER_CHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant MAINNET_CAKE = 0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant BASE_MASTER_CHEF = 0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3;
    address internal constant BASE_CAKE = 0x3055913c90Fcc1A6CE9a358911721eEb942013A1;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    address internal constant ARBITRUM_MASTER_CHEF = 0x5e09ACf80C0296740eC5d6F643005a4ef8DaA694;
    address internal constant ARBITRUM_CAKE = 0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c;
    address internal constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address internal constant BSC_MASTER_CHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant BSC_CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function testMainnetDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("MAINNET_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(MAINNET_MASTER_CHEF, MAINNET_CAKE, MAINNET_WETH, 10 ether);
    }

    function testBaseDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("BASE_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(BASE_MASTER_CHEF, BASE_CAKE, BASE_WETH, 10 ether);
    }

    function testArbitrumDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("ARBITRUM_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(ARBITRUM_MASTER_CHEF, ARBITRUM_CAKE, ARBITRUM_WETH, 10 ether);
    }

    function testBscDeploymentSmoke() external {
        string memory rpc;
        try vm.envString("BSC_RPC_URL") returns (string memory value) {
            rpc = value;
        } catch {
            return;
        }
        vm.createSelectFork(rpc);
        _deployAndAssert(BSC_MASTER_CHEF, BSC_CAKE, BSC_USDT, 100_000 ether);
        _deployAndAssert(BSC_MASTER_CHEF, BSC_CAKE, BSC_WBNB, 200 ether);
    }

    function _deployAndAssert(address masterChef, address cake, address anchor, uint256 minBalance) internal {
        IPancakeMasterChefV3 chef = IPancakeMasterChefV3(masterChef);
        assertEq(chef.CAKE(), cake);
        assertEq(chef.nonfungiblePositionManager(), PANCAKE_NPM);

        PancakeMasterChefV3Staker staker =
            new PancakeMasterChefV3Staker(INonfungiblePositionManager(PANCAKE_NPM), chef, IERC20(cake));
        PancakeMasterChefV3AutoCompound autoCompound = new PancakeMasterChefV3AutoCompound(
            INonfungiblePositionManager(PANCAKE_NPM),
            IERC20(cake),
            address(this),
            address(this),
            60,
            100,
            address(0),
            address(0)
        );

        autoCompound.setRewardAnchor(anchor, minBalance);
        autoCompound.setPancakeStaker(address(staker));
        staker.setTransformer(address(autoCompound), true);

        (bool active, uint256 configuredMinBalance) = autoCompound.rewardAnchors(anchor);
        assertTrue(active);
        assertEq(configuredMinBalance, minBalance);
    }
}
