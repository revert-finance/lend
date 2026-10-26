// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Metadata fixtures for the direct leaf receipt-token delivery path.
contract LeafDeliveryFixture {
    address public immutable RECEIPT_TOKEN;
    address public immutable LEAF_VOTER;

    constructor(address token, address voter) {
        RECEIPT_TOKEN = token;
        LEAF_VOTER = voter;
    }
}

contract LeafVoterFixture {
    address public immutable RECEIPT_TOKEN;
    address public immutable EMISSIONS_HANDLER;

    constructor(address token) {
        RECEIPT_TOKEN = token;
        EMISSIONS_HANDLER = address(new LeafDeliveryFixture(token, address(this)));
    }
}

/// @dev Receipt token of the root chain: the voter mints it to its handler and burns it on redeem.
contract ReceiptTokenFixture is ERC20 {
    constructor() ERC20("Aero receipt", "rAERO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

interface IRootTokenMinter {
    function mint(address to, uint256 amount) external;
}

/// @dev RootEmissionsHandler of the pinned snapshot: a leg that lifts the recipient's pending total to the voter's
/// MIN_REDEEM_AMOUNT redeems the whole total through the voter, a smaller leg accumulates in `pendingRedeems`.
/// It exposes LEAF_VOTER and pendingRedeems but no RECEIPT_TOKEN getter, like the upstream contract.
contract RootHandlerFixture {
    address public immutable LEAF_VOTER;
    mapping(address => uint256) public pendingRedeems;

    event RedeemDeferred(address indexed recipient, uint256 amount, uint256 pendingTotal);

    constructor(address voter) {
        LEAF_VOTER = voter;
    }

    /// @dev Desync knob: a bucket the manager never recorded (models an upgraded or buggy handler).
    function setPendingRedeems(address recipient, uint256 amount) external {
        pendingRedeems[recipient] = amount;
    }

    function handleEmissions(address[] calldata recipients, uint128[] calldata amounts) external {
        require(msg.sender == LEAF_VOTER, "CallerNotLeafVoter");
        uint256 minRedeem = RootVoterFixture(LEAF_VOTER).MIN_REDEEM_AMOUNT();
        for (uint256 i; i < recipients.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            uint256 pendingTotal = pendingRedeems[recipients[i]] + amount;
            if (pendingTotal >= minRedeem) {
                if (pendingTotal != amount) delete pendingRedeems[recipients[i]];
                RootVoterFixture(LEAF_VOTER).redeem(pendingTotal, recipients[i], 0, address(0));
            } else {
                pendingRedeems[recipients[i]] = pendingTotal;
                emit RedeemDeferred(recipients[i], amount, pendingTotal);
            }
        }
    }
}

/// @dev LeafVoter as deployed on the root chain: mintEmissions mints the receipt token to the root handler, whose
/// redeem burns it and pays the root token to the recipient in the same call (the local adapter path). Knobs model
/// the redemption floor, a failing mint (ceiling) and a failing redeem (root ceiling / suspended route).
contract RootVoterFixture {
    address public immutable RECEIPT_TOKEN;
    address public immutable ROOT_TOKEN;
    address public immutable EMISSIONS_HANDLER;
    uint256 public MIN_REDEEM_AMOUNT = 1_000_000;
    bool public mintFails;
    bool public redeemFails;
    uint256 public forfeited;

    constructor(address receiptToken, address rootToken) {
        RECEIPT_TOKEN = receiptToken;
        ROOT_TOKEN = rootToken;
        EMISSIONS_HANDLER = address(new RootHandlerFixture(address(this)));
    }

    function setMinRedeemAmount(uint256 value) external {
        MIN_REDEEM_AMOUNT = value;
    }

    function setMintFails(bool value) external {
        mintFails = value;
    }

    function setRedeemFails(bool value) external {
        redeemFails = value;
    }

    function projectedCumulativeRewardShare(address) external pure returns (uint256) {
        return 0;
    }

    function forfeitEmissions(uint128 amount) external {
        forfeited += amount;
    }

    function mintEmissions(address[] calldata recipients, uint128[] calldata amounts) external {
        require(!mintFails, "mint unavailable");
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            total += amounts[i];
        }
        if (total == 0) return;
        ReceiptTokenFixture(RECEIPT_TOKEN).mint(EMISSIONS_HANDLER, total);
        RootHandlerFixture(EMISSIONS_HANDLER).handleEmissions(recipients, amounts);
    }

    function redeem(uint256 amount, address recipient, uint256, address) external payable {
        require(amount >= MIN_REDEEM_AMOUNT, "AmountTooLow");
        require(!redeemFails, "CeilingExceeded");
        ReceiptTokenFixture(RECEIPT_TOKEN).burn(msg.sender, amount);
        IRootTokenMinter(ROOT_TOKEN).mint(recipient, amount);
    }
}

/// @dev Stands in for CLGaugeFactory's penalty/referral configuration; ABI-compatible with the upstream getters.
contract AeroGaugeFactoryFixture {
    uint256 public minStakeBlocks;
    uint256 public penaltyRate;
    address public referral;
    uint256 public referralShare;

    function setConfig(uint256 blocks_, uint256 penalty_, address referral_, uint256 share_) external {
        minStakeBlocks = blocks_;
        penaltyRate = penalty_;
        referral = referral_;
        referralShare = share_;
    }

    function effectivePenaltyConfig(address) external view returns (uint256, uint256) {
        return (minStakeBlocks, penaltyRate);
    }

    function referralConfig(address) external view returns (address, uint256) {
        return (referral, referralShare);
    }
}
