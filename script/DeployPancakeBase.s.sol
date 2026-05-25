// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./PancakeProtocolDeployment.s.sol";

contract DeployPancakeBase is PancakeProtocolDeployment {
    function run() external {
        _deploy(
            ChainConfig({
                chainId: 8453,
                label: "Base",
                npm: 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364,
                masterChef: 0xC6A2Db661D5a5690172d8eB0a7DEA2d3008665A3,
                cake: 0x3055913c90Fcc1A6CE9a358911721eEb942013A1,
                wrappedNative: 0x4200000000000000000000000000000000000006,
                defaultVaultAsset: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                defaultVaultName: "Revert Lend Base USDC",
                defaultVaultSymbol: "rlBaseUSDC"
            })
        );
    }
}
