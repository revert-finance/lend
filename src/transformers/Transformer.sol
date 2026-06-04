// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../utils/Constants.sol";
import "../interfaces/pancake/IPancakeMasterChefV3Staker.sol";

abstract contract Transformer is Ownable2Step, Constants {
    event PancakeStakerSet(address indexed staker, bool active);

    /// @notice Pancake MasterChef stakers allowed to call transformer callbacks.
    mapping(address => bool) public pancakeStakers;

    /**
     * @notice Owner controlled function to activate a Pancake staker address.
     * @param _staker Pancake MasterChef V3 staker
     */
    function setPancakeStaker(address _staker) external onlyOwner {
        _setPancakeStaker(_staker, true);
    }

    /**
     * @notice Owner controlled function to activate or deactivate a Pancake staker address.
     * @param _staker Pancake MasterChef V3 staker
     * @param _active Active state
     */
    function setPancakeStaker(address _staker, bool _active) external onlyOwner {
        _setPancakeStaker(_staker, _active);
    }

    function _setPancakeStaker(address _staker, bool _active) internal {
        if (_staker == address(0)) {
            revert InvalidConfig();
        }
        pancakeStakers[_staker] = _active;
        emit PancakeStakerSet(_staker, _active);
    }

    // validates if caller is owner (direct or indirect for a given position)
    function _validateOwner(INonfungiblePositionManager nonfungiblePositionManager, uint256 tokenId, address staker)
        internal
        view
    {
        // a staker callback cannot configure owner permissions
        if (pancakeStakers[msg.sender]) {
            revert Unauthorized();
        }

        address owner;
        if (staker != address(0)) {
            if (!pancakeStakers[staker]) {
                revert Unauthorized();
            }
            owner = IPancakeMasterChefV3Staker(staker).ownerOf(tokenId);
        } else {
            owner = nonfungiblePositionManager.ownerOf(tokenId);
        }

        if (owner != msg.sender) {
            revert Unauthorized();
        }
    }

    // validates if caller is allowed to process position
    function _validateCaller(INonfungiblePositionManager nonfungiblePositionManager, uint256 tokenId) internal view {
        if (pancakeStakers[msg.sender]) {
            uint256 transformedTokenId = IPancakeMasterChefV3Staker(msg.sender).transformedTokenId();
            if (tokenId != transformedTokenId) {
                revert Unauthorized();
            }
        } else {
            address owner = nonfungiblePositionManager.ownerOf(tokenId);
            if (owner != msg.sender && owner != address(this)) {
                revert Unauthorized();
            }
        }
    }
}
