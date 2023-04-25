// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModule {
    // adds token to module with encoded configuration in data - can be called multiple times to update configuration
    function addToken(uint256 tokenId, address owner, bytes calldata data) external;

    // withdraws token from module (if for any reason is not allowed - reverts)
    function withdrawToken(uint256 tokenId, address owner) external;

    // if needsCheckOnCollect() returns true, whenever owner or another module tries to withdraw this function is called and reverts when not agree
    function checkOnCollect(uint256 tokenId, address owner, uint128 liquidity, uint256 amount0, uint256 amount1) external;

    // defines if this module does checks of collects
    function needsCheckOnCollect() external returns (bool);

    // returns encoded config for a given token
    function getConfig(uint256 tokenId) external view returns (bytes memory config);

    // callback which allows using the decreased liquidity before other modules are checked
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint256 amount0, uint256 amount1, bytes memory data) external returns (bytes memory returnData);   
}