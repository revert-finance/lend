// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
import {MockERC20Token} from "../unit/GaugeManager.t.sol";

/// @dev Models the verified root handler's one-for-one, all-or-nothing threshold settlement.
contract RootSettlementFixture {
    uint256 public constant MIN_REDEEM_AMOUNT = 1_000_000;
    address public LEAF_VOTER;
    MockERC20Token public immutable token;
    mapping(address => uint256) public pendingRedeems;

    constructor(MockERC20Token token_) {
        token = token_;
    }

    function setVoter(address voter) external {
        LEAF_VOTER = voter;
    }

    function mint(address recipient, uint256 amount) external {
        if (amount == 0) return;
        uint256 total = pendingRedeems[recipient] + amount;
        if (total >= MIN_REDEEM_AMOUNT) {
            delete pendingRedeems[recipient];
            token.mint(recipient, total);
        } else {
            pendingRedeems[recipient] = total;
        }
    }
}

/// @dev Compact metadata double for the local voter/orchestrator/adapter graph; live graph is tested separately.
contract RootTopologyFixture {
    address public RECEIPT_TOKEN = address(0x123456);
    address public EMISSIONS_HANDLER;
    address public TOKEN;
    uint256 public ROOT_CHAIN_ID = block.chainid;

    constructor(address handler, address token) {
        EMISSIONS_HANDLER = handler;
        TOKEN = token;
    }

    function ORCHESTRATOR() external view returns (address) {
        return address(this);
    }

    function adapter() external view returns (address) {
        return address(this);
    }

    function REMOTE_CHAIN_ID() external view returns (uint256) {
        return block.chainid;
    }

    function ROOT_MESSAGE_ORCHESTRATOR() external view returns (address) {
        return address(this);
    }

    function LEAF_MESSAGE_ORCHESTRATOR() external view returns (address) {
        return address(this);
    }

    function VOTER() external view returns (address) {
        return address(this);
    }

    function setRootChain(uint256 chainId) external {
        ROOT_CHAIN_ID = chainId;
    }

    function setToken(address token) external {
        TOKEN = token;
    }
}
