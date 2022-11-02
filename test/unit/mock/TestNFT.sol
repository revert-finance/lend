// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestNFT is ERC721 {

    uint currentId;

    constructor() ERC721("Test NFT", "TNFT") {

    }

    function mint() external returns(uint) {
        _mint(msg.sender, ++currentId);
        return currentId;
    }

    function burn(uint tokenId) external {
        _burn(tokenId);
    }
}