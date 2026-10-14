// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAeroGauge} from "../../src/interfaces/aero/IAeroGauge.sol";
import {LeafVoterFixture, AeroGaugeFactoryFixture} from "./AeroDeliveryFixture.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @dev Aero CLGauge double with the claim-or-defer withdrawal semantics of the pinned upstream contract.
/// Knobs model delivery outages (failed mints defer into the account bucket), retired deposits, withdrawal-time
/// reward and fee payouts, and bookkeeping desyncs. The unmodified upstream bytecode is exercised separately.
contract AeroGaugeFixture is IAeroGauge {
    address public override voter;
    address public immutable override gaugeFactory;
    address public immutable override nft;
    address public immutable override pool;
    IMintableToken public immutable token;
    mapping(uint256 => address) public staker;
    mapping(uint256 => uint256) public override depositBlock;
    mapping(uint256 => uint256) public rewards;
    mapping(address => uint256) public override deferredEmissions;
    bool public mintFails;
    bool public claimFails;
    bool public depositsDisabled;
    bool public withdrawClearsBucket;
    uint256 public withdrawalReward;
    IMintableToken public feeToken;
    uint256 public feeAmount;

    constructor(address nft_, address pool_, address token_) {
        nft = nft_;
        pool = pool_;
        token = IMintableToken(token_);
        voter = address(new LeafVoterFixture(token_));
        gaugeFactory = address(new AeroGaugeFactoryFixture());
    }

    function setVoter(address value) external {
        voter = value;
    }

    function setMintFails(bool value) external {
        mintFails = value;
    }

    function setClaimFails(bool value) external {
        claimFails = value;
    }

    function setDepositsDisabled(bool value) external {
        depositsDisabled = value;
    }

    /// @dev Desync knobs: force the account bucket to a value the manager never recorded, or make a
    /// withdrawal shrink it. Neither happens with the pinned upstream gauge; they model a buggy or upgraded one.
    function setDeferredEmissions(address account, uint256 amount) external {
        deferredEmissions[account] = amount;
    }

    function setWithdrawClearsBucket(bool value) external {
        withdrawClearsBucket = value;
    }

    function setReward(uint256 id, uint256 amount) external {
        rewards[id] = amount;
    }

    function setWithdrawalReward(uint256 amount) external {
        withdrawalReward = amount;
    }

    function setFees(address token_, uint256 amount) external {
        feeToken = IMintableToken(token_);
        feeAmount = amount;
    }

    function deposit(uint256 id) external override {
        require(!depositsDisabled, "retired");
        IERC721(nft).transferFrom(msg.sender, address(this), id);
        staker[id] = msg.sender;
        depositBlock[id] = block.number;
    }

    function earned(address account, uint256[] calldata ids) external view override returns (uint256 amount) {
        amount = deferredEmissions[account];
        for (uint256 i; i < ids.length; ++i) {
            require(staker[ids[i]] == account, "not staker");
            amount += rewards[ids[i]];
        }
    }

    function claimEmissions(address account, address recipient, uint256[] calldata ids) external override {
        require(msg.sender == account, "not account");
        require(!claimFails, "claim unavailable");
        uint256 amount = deferredEmissions[account];
        require(ids.length != 0 || amount != 0, "nothing to claim");
        delete deferredEmissions[account];
        for (uint256 i; i < ids.length; ++i) {
            require(staker[ids[i]] == account, "not staker");
            amount += rewards[ids[i]];
            delete rewards[ids[i]];
        }
        if (amount != 0) {
            require(!mintFails, "mint unavailable");
            token.mint(recipient, amount);
        }
    }

    function withdraw(uint256 id) external override {
        require(staker[id] == msg.sender, "not staker");
        uint256 amount = rewards[id] + withdrawalReward;
        delete rewards[id];
        delete staker[id];
        delete depositBlock[id];
        if (withdrawClearsBucket) delete deferredEmissions[msg.sender];
        if (mintFails) deferredEmissions[msg.sender] += amount;
        else if (amount != 0) token.mint(msg.sender, amount);
        if (feeAmount != 0) feeToken.mint(msg.sender, feeAmount);
        IERC721(nft).safeTransferFrom(address(this), msg.sender, id);
    }
}
