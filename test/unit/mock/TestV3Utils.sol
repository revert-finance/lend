// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract TestV3Utils is IERC721Receiver {
   
    error WrongContract();

    /// @notice Uniswap v3 position manager
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    /// @notice Constructor
    /// @param _nonfungiblePositionManager Uniswap v3 position manager
    constructor(INonfungiblePositionManager _nonfungiblePositionManager) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }


    /// @notice ERC721 callback function. Called on safeTransferFrom and does manipulation as configured in encoded Instructions parameter. At the end the NFT and any leftover tokens are returned to sender.
    function onERC721Received(address , address from, uint256 tokenId, bytes calldata data) external override returns (bytes4) {
        
        // only Uniswap v3 NFTs allowed
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        // return token to owner (this line guarantees that token is returned to originating owner)
        nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, "");

        return IERC721Receiver.onERC721Received.selector;
    }
}