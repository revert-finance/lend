// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../src/InterestRateModel.sol";
import "../src/PancakeStakingManager.sol";
import "../src/V3Oracle.sol";
import "../src/V3Vault.sol";
import "../src/automators/AutoExit.sol";
import "../src/interfaces/pancake/IPancakeMasterChefV3.sol";
import "../src/transformers/AutoRangeAndCompound.sol";
import "../src/transformers/LeverageTransformer.sol";
import "../src/transformers/V3Utils.sol";
import "../src/utils/FlashloanLiquidator.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

interface IOwnable2StepView is IOwnableView {
    function pendingOwner() external view returns (address);
}

contract VerifyPancakeDeployment is Script {
    struct Deployment {
        InterestRateModel interestRateModel;
        V3Oracle oracle;
        V3Vault vault;
        FlashloanLiquidator flashloanLiquidator;
        V3Utils v3Utils;
        LeverageTransformer leverageTransformer;
        AutoRangeAndCompound autoRange;
        AutoExit autoExit;
        PancakeStakingManager stakingManager;
        INonfungiblePositionManager npm;
        IPancakeMasterChefV3 masterChef;
        address cake;
    }

    struct ExpectedConfig {
        address owner;
        address operator;
        address withdrawer;
        address stakingWithdrawer;
        address vaultAsset;
        address referenceToken;
        address chainlinkReferenceToken;
        address universalRouter;
        address zeroxAllowanceHolder;
        bool setVaultGaugeManager;
        address[] oracleTokens;
        address[] collateralTokens;
        address[] rewardBaseTokens;
        address[] rewardBasePools;
        address[] stakingPools;
    }

    function run() external {
        Deployment memory deployed = Deployment({
            interestRateModel: InterestRateModel(vm.envAddress("INTEREST_RATE_MODEL")),
            oracle: V3Oracle(vm.envAddress("ORACLE")),
            vault: V3Vault(payable(vm.envAddress("VAULT"))),
            flashloanLiquidator: FlashloanLiquidator(vm.envAddress("FLASHLOAN_LIQUIDATOR")),
            v3Utils: V3Utils(payable(vm.envAddress("V3_UTILS"))),
            leverageTransformer: LeverageTransformer(vm.envAddress("LEVERAGE_TRANSFORMER")),
            autoRange: AutoRangeAndCompound(payable(vm.envAddress("AUTO_RANGE"))),
            autoExit: AutoExit(payable(vm.envAddress("AUTO_EXIT"))),
            stakingManager: PancakeStakingManager(payable(vm.envAddress("PANCAKE_STAKING_MANAGER"))),
            npm: INonfungiblePositionManager(vm.envAddress("PANCAKE_NPM")),
            masterChef: IPancakeMasterChefV3(vm.envAddress("PANCAKE_MASTER_CHEF_V3")),
            cake: vm.envAddress("CAKE")
        });

        ExpectedConfig memory expected = ExpectedConfig({
            owner: _envAddressOrDefault("OWNER", address(0)),
            operator: _envAddressOrDefault("OPERATOR", address(0)),
            withdrawer: _envAddressOrDefault("WITHDRAWER", address(0)),
            stakingWithdrawer: _envAddressOrDefault("STAKING_WITHDRAWER", address(0)),
            vaultAsset: _envAddressOrDefault("VAULT_ASSET", address(0)),
            referenceToken: _envAddressOrDefault("REFERENCE_TOKEN", address(0)),
            chainlinkReferenceToken: _envAddressOrDefault("CHAINLINK_REFERENCE_TOKEN", address(0)),
            universalRouter: _envAddressOrDefault("UNIVERSAL_ROUTER", address(0)),
            zeroxAllowanceHolder: _envAddressOrDefault("ZEROX_ALLOWANCE_HOLDER", address(0)),
            setVaultGaugeManager: _envBoolOrDefault("SET_VAULT_GAUGE_MANAGER", true),
            oracleTokens: _envAddressArrayOrEmpty("ORACLE_TOKENS"),
            collateralTokens: _envAddressArrayOrEmpty("COLLATERAL_TOKENS"),
            rewardBaseTokens: _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_TOKENS"),
            rewardBasePools: _envAddressArrayOrEmpty("PANCAKE_REWARD_BASE_POOLS"),
            stakingPools: _envAddressArrayOrEmpty("PANCAKE_STAKING_POOLS")
        });

        _verifyCode(deployed);
        _verifyExternalConfig(deployed);
        _verifyVaultAndHelpers(deployed, expected);
        _verifyOwnership(deployed, expected.owner);
        _verifyConfiguredArrays(deployed, expected);

        console2.log("PANCAKE_DEPLOYMENT_VERIFIED", true);
    }

    function _verifyCode(Deployment memory deployed) internal view {
        _requireCode(address(deployed.interestRateModel), "VerifyPancake: InterestRateModel missing code");
        _requireCode(address(deployed.oracle), "VerifyPancake: V3Oracle missing code");
        _requireCode(address(deployed.vault), "VerifyPancake: V3Vault missing code");
        _requireCode(address(deployed.flashloanLiquidator), "VerifyPancake: FlashloanLiquidator missing code");
        _requireCode(address(deployed.v3Utils), "VerifyPancake: V3Utils missing code");
        _requireCode(address(deployed.leverageTransformer), "VerifyPancake: LeverageTransformer missing code");
        _requireCode(address(deployed.autoRange), "VerifyPancake: AutoRange missing code");
        _requireCode(address(deployed.autoExit), "VerifyPancake: AutoExit missing code");
        _requireCode(address(deployed.stakingManager), "VerifyPancake: staking manager missing code");
        _requireCode(address(deployed.npm), "VerifyPancake: Pancake NPM missing code");
        _requireCode(address(deployed.masterChef), "VerifyPancake: MasterChef missing code");
        _requireCode(deployed.cake, "VerifyPancake: CAKE missing code");
    }

    function _verifyExternalConfig(Deployment memory deployed) internal view {
        _requireEqual(deployed.masterChef.CAKE(), deployed.cake, "VerifyPancake: MasterChef CAKE mismatch");
        _requireEqual(
            deployed.masterChef.nonfungiblePositionManager(),
            address(deployed.npm),
            "VerifyPancake: MasterChef NPM mismatch"
        );
        _requireEqual(deployed.npm.factory(), address(deployed.vault.factory()), "VerifyPancake: factory mismatch");
    }

    function _verifyVaultAndHelpers(Deployment memory deployed, ExpectedConfig memory expected) internal view {
        if (expected.vaultAsset != address(0)) {
            _requireEqual(deployed.vault.asset(), expected.vaultAsset, "VerifyPancake: vault asset mismatch");
        }
        if (expected.referenceToken != address(0)) {
            _requireEqual(deployed.oracle.referenceToken(), expected.referenceToken, "VerifyPancake: reference token");
        }
        _requireEqual(
            deployed.oracle.chainlinkReferenceToken(),
            expected.chainlinkReferenceToken,
            "VerifyPancake: chainlink reference token"
        );

        _requireEqual(
            address(deployed.vault.interestRateModel()), address(deployed.interestRateModel), "VerifyPancake: IRM"
        );
        _requireEqual(address(deployed.vault.oracle()), address(deployed.oracle), "VerifyPancake: oracle");
        _requireEqual(
            address(deployed.vault.nonfungiblePositionManager()), address(deployed.npm), "VerifyPancake: vault NPM"
        );

        if (expected.setVaultGaugeManager) {
            _requireEqual(
                deployed.vault.gaugeManager(), address(deployed.stakingManager), "VerifyPancake: gauge manager"
            );
        }

        _requireEqual(
            address(deployed.stakingManager.nonfungiblePositionManager()),
            address(deployed.npm),
            "VerifyPancake: staking manager NPM"
        );
        _requireEqual(
            address(deployed.stakingManager.masterChef()),
            address(deployed.masterChef),
            "VerifyPancake: staking manager MasterChef"
        );
        _requireEqual(address(deployed.stakingManager.cakeToken()), deployed.cake, "VerifyPancake: cake token");
        _requireEqual(address(deployed.stakingManager.vault()), address(deployed.vault), "VerifyPancake: staking vault");

        _verifySwapperConfig(address(deployed.flashloanLiquidator), deployed, expected, "VerifyPancake: flashloan");
        _verifySwapperConfig(address(deployed.v3Utils), deployed, expected, "VerifyPancake: v3Utils");
        _verifySwapperConfig(address(deployed.leverageTransformer), deployed, expected, "VerifyPancake: leverage");
        _verifySwapperConfig(address(deployed.autoRange), deployed, expected, "VerifyPancake: autoRange");
        _verifySwapperConfig(address(deployed.autoExit), deployed, expected, "VerifyPancake: autoExit");
        _verifySwapperConfig(address(deployed.stakingManager), deployed, expected, "VerifyPancake: staking");

        _requireTrue(
            deployed.vault.transformerAllowList(address(deployed.v3Utils)), "VerifyPancake: V3Utils not allowed"
        );
        _requireTrue(
            deployed.vault.transformerAllowList(address(deployed.leverageTransformer)),
            "VerifyPancake: leverage not allowed"
        );
        _requireTrue(
            deployed.vault.transformerAllowList(address(deployed.autoRange)), "VerifyPancake: autoRange not allowed"
        );
        _requireTrue(deployed.v3Utils.vaults(address(deployed.vault)), "VerifyPancake: V3Utils vault missing");
        _requireTrue(
            deployed.leverageTransformer.vaults(address(deployed.vault)), "VerifyPancake: leverage vault missing"
        );
        _requireTrue(deployed.autoRange.vaults(address(deployed.vault)), "VerifyPancake: autoRange vault missing");

        if (expected.operator != address(0)) {
            _requireTrue(deployed.autoRange.operators(expected.operator), "VerifyPancake: autoRange operator");
            _requireTrue(deployed.autoExit.operators(expected.operator), "VerifyPancake: autoExit operator");
        }
        if (expected.withdrawer != address(0)) {
            _requireEqual(deployed.autoRange.withdrawer(), expected.withdrawer, "VerifyPancake: autoRange withdrawer");
            _requireEqual(deployed.autoExit.withdrawer(), expected.withdrawer, "VerifyPancake: autoExit withdrawer");
        }
        if (expected.stakingWithdrawer != address(0)) {
            _requireEqual(
                deployed.stakingManager.withdrawer(), expected.stakingWithdrawer, "VerifyPancake: staking withdrawer"
            );
        }
    }

    function _verifySwapperConfig(
        address target,
        Deployment memory deployed,
        ExpectedConfig memory expected,
        string memory label
    ) internal view {
        SwapperView swapper = SwapperView(target);
        _requireEqual(
            address(swapper.nonfungiblePositionManager()), address(deployed.npm), string.concat(label, " NPM")
        );
        _requireEqual(swapper.factory(), deployed.npm.factory(), string.concat(label, " factory"));
        _requireEqual(swapper.universalRouter(), expected.universalRouter, string.concat(label, " universal router"));
        _requireEqual(swapper.zeroxAllowanceHolder(), expected.zeroxAllowanceHolder, string.concat(label, " 0x holder"));
    }

    function _verifyOwnership(Deployment memory deployed, address owner) internal view {
        if (owner == address(0)) {
            return;
        }
        _requireEqual(IOwnableView(address(deployed.interestRateModel)).owner(), owner, "VerifyPancake: IRM owner");
        _verifyOwnerOrPending(address(deployed.oracle), owner, "VerifyPancake: oracle owner");
        _verifyOwnerOrPending(address(deployed.vault), owner, "VerifyPancake: vault owner");
        _verifyOwnerOrPending(address(deployed.v3Utils), owner, "VerifyPancake: V3Utils owner");
        _verifyOwnerOrPending(address(deployed.leverageTransformer), owner, "VerifyPancake: leverage owner");
        _verifyOwnerOrPending(address(deployed.autoRange), owner, "VerifyPancake: autoRange owner");
        _verifyOwnerOrPending(address(deployed.autoExit), owner, "VerifyPancake: autoExit owner");
        _verifyOwnerOrPending(address(deployed.stakingManager), owner, "VerifyPancake: staking owner");
    }

    function _verifyConfiguredArrays(Deployment memory deployed, ExpectedConfig memory expected) internal view {
        for (uint256 i; i < expected.oracleTokens.length; ++i) {
            _requireTrue(deployed.oracle.isTokenConfigured(expected.oracleTokens[i]), "VerifyPancake: oracle token");
        }

        for (uint256 i; i < expected.collateralTokens.length; ++i) {
            (uint32 collateralFactorX32,,) = deployed.vault.tokenConfigs(expected.collateralTokens[i]);
            _requireTrue(collateralFactorX32 != 0, "VerifyPancake: collateral token");
        }

        _requireEqual(
            expected.rewardBaseTokens.length, expected.rewardBasePools.length, "VerifyPancake: reward route length"
        );
        for (uint256 i; i < expected.rewardBaseTokens.length; ++i) {
            address token = expected.rewardBaseTokens[i];
            address pool = expected.rewardBasePools[i];
            _requireEqual(deployed.stakingManager.rewardBasePools(token), pool, "VerifyPancake: reward route");
            _verifyRewardPool(deployed, token, pool);
        }

        for (uint256 i; i < expected.stakingPools.length; ++i) {
            address pool = expected.stakingPools[i];
            _requireEqual(
                deployed.stakingManager.poolToGauge(pool), address(deployed.masterChef), "VerifyPancake: gauge"
            );
            _verifyStakingPool(deployed, pool);
        }
    }

    function _verifyRewardPool(Deployment memory deployed, address baseToken, address pool) internal view {
        _requireCode(baseToken, "VerifyPancake: reward base token missing code");
        _requireCode(pool, "VerifyPancake: reward pool missing code");

        IUniswapV3Pool rewardPool = IUniswapV3Pool(pool);
        address token0 = rewardPool.token0();
        address token1 = rewardPool.token1();
        _requireTrue(
            token0 == deployed.cake && token1 == baseToken || token0 == baseToken && token1 == deployed.cake,
            "VerifyPancake: invalid reward pool"
        );
        _requireEqual(
            IUniswapV3Factory(deployed.npm.factory()).getPool(token0, token1, rewardPool.fee()),
            pool,
            "VerifyPancake: unknown reward pool"
        );
    }

    function _verifyStakingPool(Deployment memory deployed, address pool) internal view {
        _requireCode(pool, "VerifyPancake: staking pool missing code");

        uint256 pid = deployed.masterChef.v3PoolAddressPid(pool);
        _requireTrue(pid != 0, "VerifyPancake: pool not in MasterChef");
        (, IUniswapV3Pool v3Pool, address token0, address token1, uint24 fee,,) = deployed.masterChef.poolInfo(pid);
        _requireEqual(address(v3Pool), pool, "VerifyPancake: MasterChef pool mismatch");
        _requireEqual(
            IUniswapV3Factory(deployed.npm.factory()).getPool(token0, token1, fee),
            pool,
            "VerifyPancake: unknown staking pool"
        );
    }

    function _verifyOwnerOrPending(address target, address expectedOwner, string memory label) internal view {
        IOwnable2StepView ownable = IOwnable2StepView(target);
        if (ownable.owner() == expectedOwner) {
            return;
        }
        _requireEqual(ownable.pendingOwner(), expectedOwner, label);
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

    function _requireCode(address target, string memory message) internal view {
        require(target.code.length != 0, message);
    }

    function _requireEqual(address actual, address expected, string memory message) internal pure {
        require(actual == expected, message);
    }

    function _requireEqual(uint256 actual, uint256 expected, string memory message) internal pure {
        require(actual == expected, message);
    }

    function _requireTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }
}

interface SwapperView {
    function factory() external view returns (address);
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);
    function universalRouter() external view returns (address);
    function zeroxAllowanceHolder() external view returns (address);
}
