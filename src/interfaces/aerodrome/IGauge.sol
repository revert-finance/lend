// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
}
