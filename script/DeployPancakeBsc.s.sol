// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./PancakeProtocolDeployment.s.sol";

contract DeployPancakeBsc is PancakeProtocolDeployment {
    function run() external {
        _deploy(
            ChainConfig({
                chainId: 56,
                label: "BSC",
                npm: 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364,
                masterChef: 0x556B9306565093C855AEA9AE92A594704c2Cd59e,
                cake: 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82,
                wrappedNative: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                defaultVaultAsset: 0x55d398326f99059fF775485246999027B3197955,
                defaultVaultName: "Revert Lend BSC USDT",
                defaultVaultSymbol: "rlBscUSDT"
            })
        );
    }
}
