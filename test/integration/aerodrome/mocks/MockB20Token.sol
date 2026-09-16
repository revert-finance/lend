// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../../../src/interfaces/IB20Multiplier.sol";

/// @notice Stand-in for a Base B20 tokenized stock: 8 decimals, an issuer-controlled
///         corporate-action multiplier, and address-level transfer gating (policy blocklist).
///         The real tokens are native client code (0xef) and cannot run on a fork.
contract MockB20Token is ERC20, IB20Multiplier {
    uint256 private _multiplier = 1e18;
    bool private _revertMultiplier;
    mapping(address => bool) public blocked;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public view virtual override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMultiplier(uint256 multiplier_) external {
        _multiplier = multiplier_;
    }

    /// @dev simulates the native "not implemented" selector revert seen on uiMultiplier() etc.
    function setRevertMultiplier(bool revert_) external {
        _revertMultiplier = revert_;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function multiplier() external view override returns (uint256) {
        require(!_revertMultiplier, "B20: not implemented");
        return _multiplier;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        require(!blocked[from] && !blocked[to] && !blocked[msg.sender], "B20: policy");
        super._beforeTokenTransfer(from, to, amount);
    }
}
