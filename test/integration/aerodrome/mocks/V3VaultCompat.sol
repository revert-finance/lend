// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../../../src/V3Vault.sol";
import "../../../../src/interfaces/IGaugeManager.sol";

/// @notice Test-only adapter that provides backward-compatible helpers expected by PR47 test suites.
contract V3VaultCompat is V3Vault {
    constructor(
        string memory name,
        string memory symbol,
        address _asset,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IInterestRateModel _interestRateModel,
        IV3Oracle _oracle,
        address _permit2
    ) V3Vault(
        name,
        symbol,
        _asset,
        _nonfungiblePositionManager,
        _interestRateModel,
        _oracle,
        IPermit2(_permit2)
    ) {}

    function pendingDepositRecipient(uint256) external pure returns (address) {
        return address(0);
    }

    function claimRewards(uint256 tokenId) external returns (uint256 aeroAmount) {
        if (gaugeManager == address(0)) {
            revert GaugeManagerNotSet();
        }
        if (this.ownerOf(tokenId) != msg.sender) {
            revert Unauthorized();
        }
        aeroAmount = IGaugeManager(gaugeManager).claimRewards(tokenId, msg.sender);
    }

    function unstakeTransformStake(uint256 tokenId, address transformer, bytes calldata data)
        external
        returns (uint256 newTokenId)
    {
        address owner = this.ownerOf(tokenId);
        if (owner != msg.sender && !transformApprovals[owner][tokenId][msg.sender]) {
            revert Unauthorized();
        }

        transformApprovals[owner][tokenId][address(this)] = true;
        newTokenId = this.transform(tokenId, transformer, data);

        delete transformApprovals[owner][tokenId][address(this)];
        if (newTokenId != tokenId) {
            delete transformApprovals[owner][newTokenId][address(this)];
        }
    }
}
