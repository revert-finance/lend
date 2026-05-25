// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../src/PancakeStakingManager.sol";
import "../src/interfaces/IVault.sol";
import "../src/interfaces/pancake/IPancakeMasterChefV3.sol";

contract DeployPancakeStakingManager is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        INonfungiblePositionManager npm = INonfungiblePositionManager(vm.envAddress("PANCAKE_NPM"));
        IPancakeMasterChefV3 masterChef = IPancakeMasterChefV3(vm.envAddress("PANCAKE_MASTER_CHEF_V3"));
        IERC20 cake = IERC20(vm.envAddress("CAKE"));
        IVault vault = IVault(vm.envAddress("VAULT"));
        address universalRouter = _envAddressOrDefault("UNIVERSAL_ROUTER", address(0));
        address zeroxAllowanceHolder = _envAddressOrDefault("ZEROX_ALLOWANCE_HOLDER", address(0));
        address withdrawer = _envAddressOrDefault("WITHDRAWER", deployer);
        address owner = _envAddressOrDefault("OWNER", address(0));
        bool setVaultGaugeManager = _envBoolOrDefault("SET_VAULT_GAUGE_MANAGER", false);

        address[] memory rewardBaseTokens = _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_TOKENS");
        address[] memory rewardBasePools = _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_POOLS");
        address[] memory stakingPools = _envAddressArrayOrEmpty("PANCAKE_STAKING_POOLS");

        _validateArrayLength(rewardBaseTokens.length, rewardBasePools.length, "reward route length mismatch");
        _requireCode(address(npm), "Pancake NPM missing code");
        _requireCode(address(masterChef), "Pancake MasterChefV3 missing code");
        _requireCode(address(cake), "CAKE missing code");
        _requireCode(address(vault), "Vault missing code");
        _requireNonZero(withdrawer, "withdrawer zero");
        require(masterChef.CAKE() == address(cake), "CAKE mismatch");
        require(masterChef.nonfungiblePositionManager() == address(npm), "NPM mismatch");

        for (uint256 i; i < rewardBasePools.length; ++i) {
            _validateRewardPool(npm, address(cake), rewardBaseTokens[i], rewardBasePools[i]);
        }
        for (uint256 i; i < stakingPools.length; ++i) {
            _validateStakingPool(npm, masterChef, stakingPools[i]);
        }

        vm.startBroadcast(deployer);

        PancakeStakingManager stakingManager =
            new PancakeStakingManager(npm, masterChef, cake, vault, universalRouter, zeroxAllowanceHolder);

        for (uint256 i; i < rewardBasePools.length; ++i) {
            stakingManager.setRewardBasePool(rewardBaseTokens[i], rewardBasePools[i]);
        }
        for (uint256 i; i < stakingPools.length; ++i) {
            stakingManager.setGauge(stakingPools[i], address(masterChef));
        }

        stakingManager.setWithdrawer(withdrawer);
        if (setVaultGaugeManager) {
            vault.setGaugeManager(address(stakingManager));
        }
        if (owner != address(0)) {
            stakingManager.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console2.log("DEPLOYER", deployer);
        console2.log("PANCAKE_STAKING_MANAGER", address(stakingManager));
        console2.log("PANCAKE_MASTER_CHEF_V3", address(masterChef));
        console2.log("VAULT", address(vault));
        console2.log("WITHDRAWER", withdrawer);
        console2.log("OWNER", owner == address(0) ? deployer : owner);
    }

    function _validateRewardPool(INonfungiblePositionManager npm, address cake, address baseToken, address pool)
        internal
        view
    {
        _requireNonZero(baseToken, "reward base token zero");
        _requireCode(pool, "reward pool missing code");
        IUniswapV3Pool rewardPool = IUniswapV3Pool(pool);
        address token0 = rewardPool.token0();
        address token1 = rewardPool.token1();
        require(token0 == cake && token1 == baseToken || token0 == baseToken && token1 == cake, "invalid reward pool");
        require(
            IUniswapV3Factory(npm.factory()).getPool(token0, token1, rewardPool.fee()) == pool, "unknown reward pool"
        );
    }

    function _validateStakingPool(INonfungiblePositionManager npm, IPancakeMasterChefV3 masterChef, address pool)
        internal
        view
    {
        _requireCode(pool, "staking pool missing code");
        uint256 pid = masterChef.v3PoolAddressPid(pool);
        require(pid != 0, "staking pool not in MasterChef");
        (, IUniswapV3Pool v3Pool, address token0, address token1, uint24 fee,,) = masterChef.poolInfo(pid);
        require(address(v3Pool) == pool, "MasterChef pool mismatch");
        require(IUniswapV3Factory(npm.factory()).getPool(token0, token1, fee) == pool, "unknown staking pool");
    }

    function _validateArrayLength(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    function _requireCode(address target, string memory errorMessage) internal view {
        require(target.code.length != 0, errorMessage);
    }

    function _requireNonZero(address target, string memory errorMessage) internal pure {
        require(target != address(0), errorMessage);
    }

    function _envAddressOrDefault(string memory key, address defaultValue) internal returns (address value) {
        try vm.envAddress(key) returns (address configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envBoolOrDefault(string memory key, bool defaultValue) internal returns (bool value) {
        try vm.envBool(key) returns (bool configuredValue) {
            value = configuredValue;
        } catch {
            value = defaultValue;
        }
    }

    function _envAddressArrayOrEmpty(string memory key) internal returns (address[] memory value) {
        try vm.envAddress(key, ",") returns (address[] memory configuredValue) {
            value = configuredValue;
        } catch {
            value = new address[](0);
        }
    }
}
