// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

interface IAeroRecoveryOwner {
    function owner() external view returns (address);
    function transferOwnership(address) external;
}

interface IAeroRecoveryVault is IAeroRecoveryOwner {
    function asset() external view returns (address);
    function oracle() external view returns (address);
    function interestRateModel() external view returns (address);
    function gaugeManager() external view returns (address);
    function globalDebtLimit() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function debtSharesTotal() external view returns (uint256);
    function reserveFactorX32() external view returns (uint32);
    function reserveProtectionFactorX32() external view returns (uint32);
    function setReserveFactor(uint32) external;
    function setReserveProtectionFactor(uint32) external;
    function setTokenConfig(address, uint32, uint32) external;
}

/// @notice Complete only the remaining configuration for the deployment started at Base block 53165717.
/// No contract creation, vault binding, borrowing activation, or protocol-code changes.
contract CompleteAeroProtocolDeployment is Script {
    address constant DEPLOYER = 0x83681C14770b44361e21Faf91D8325423365eA5C;
    address constant SAFE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address constant ORACLE = 0x24B58808ca5891d9B58E04dB1b03a5E980F648b5;
    address constant IRM = 0x12DABa2089F8e81c814Cf40945e5bDaE43393eA2;
    address constant VAULT = 0x1c69eb478425199D34D93484c76c1B39554979a1;
    address constant MANAGER = 0x1AC3a1C018a09146dcE000eFcC67e2129aDc6DBD;
    address constant UTILS = 0x1D388deC5C440f572D3103B09f22aCd674b707f5;
    address constant LEVERAGE = 0xAD3a04Af07Bbd1daAB2e0938359FE4fB4A786690;
    address constant AUTO_RANGE = 0x1d0B1401AFdd36aFCAc521DaC95a7F1906BAD642;
    address constant AUTO_EXIT = 0x5793aed47c74b53a67c864ca080136Ba4E8452b8;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function run() external {
        require(block.chainid == 8453, "Base only");
        IAeroRecoveryVault vault = IAeroRecoveryVault(VAULT);
        address[8] memory owned = [ORACLE, IRM, VAULT, MANAGER, UTILS, LEVERAGE, AUTO_RANGE, AUTO_EXIT];
        for (uint256 i; i < owned.length; ++i) {
            require(IAeroRecoveryOwner(owned[i]).owner() == DEPLOYER, "inspect ownership before recovery");
        }
        require(vault.asset() == USDC && vault.oracle() == ORACLE, "vault asset/oracle mismatch");
        require(vault.interestRateModel() == IRM && vault.gaugeManager() == MANAGER, "vault binding mismatch");
        require(vault.globalDebtLimit() == 0, "borrowing must remain disabled");
        require(vault.totalSupply() == 0 && vault.debtSharesTotal() == 0, "vault already used");
        require(vault.reserveFactorX32() == 0, "reserve factor already set; inspect before recovery");

        vm.startBroadcast(DEPLOYER);
        // The original same-timestamp simulation skipped interest accrual. Real transactions cross blocks.
        // Explicit gas headroom covers that path without changing any deployed contract.
        vault.setReserveFactor{gas: 250_000}(429496729);
        vault.setReserveProtectionFactor{gas: 250_000}(214748364);
        vault.setTokenConfig{gas: 250_000}(USDC, 3650722201, type(uint32).max);
        vault.setTokenConfig{gas: 250_000}(WETH, 3328599654, type(uint32).max);
        vault.setTokenConfig{gas: 250_000}(CBBTC, 3328599654, type(uint32).max);
        for (uint256 i; i < owned.length; ++i) {
            IAeroRecoveryOwner(owned[i]).transferOwnership{gas: 250_000}(SAFE);
        }
        vm.stopBroadcast();
        require(vault.reserveFactorX32() == 429496729, "reserve factor");
        require(vault.reserveProtectionFactorX32() == 214748364, "reserve protection");
        require(vault.globalDebtLimit() == 0, "debt cap");
        require(IAeroRecoveryOwner(IRM).owner() == SAFE, "IRM owner");
        console.log("Completed existing Aero deployment. Borrowing remains disabled.");
        console.log("VAULT", VAULT);
        console.log("SAFE", SAFE);
    }
}
