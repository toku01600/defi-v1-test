// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPoolCore {
    function listAsset(address asset, uint16 cfBps) external;
    function setCollateralFactor(address asset, uint16 newCfBps) external;
}

contract SimpleDAO {
    struct Proposal {
        address target;
        bytes data;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    mapping(address => bool) public members; // シンプルにホワイトリスト制
    mapping(uint256 => mapping(address => bool)) public voted;

    event Proposed(uint256 id, address proposer, address target, bytes data);
    event Voted(uint256 id, address voter, bool support);
    event Executed(uint256 id);

    constructor(address[] memory initialMembers) {
        for (uint256 i = 0; i < initialMembers.length; i++) {
            members[initialMembers[i]] = true;
        }
    }

    modifier onlyMember() {
        require(members[msg.sender], "not member");
        _;
    }

    function propose(address target, bytes calldata data) external onlyMember returns (uint256) {
        proposalCount++;
        proposals[proposalCount] = Proposal(target, data, 0, 0, false);
        emit Proposed(proposalCount, msg.sender, target, data);
        return proposalCount;
    }

    function vote(uint256 id, bool support) external onlyMember {
        require(!voted[id][msg.sender], "already voted");
        Proposal storage p = proposals[id];
        require(!p.executed, "executed");
        voted[id][msg.sender] = true;

        if (support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }
        emit Voted(id, msg.sender, support);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.executed, "already executed");
        require(p.yesVotes > p.noVotes, "not passed");

        (bool ok, ) = p.target.call(p.data);
        require(ok, "exec failed");
        p.executed = true;
        emit Executed(id);
    }

    // ==== ヘルパー ====
    function proposeSetCollateralFactor(address pool, address asset, uint16 newCfBps) external onlyMember returns (uint256) {
        bytes memory data = abi.encodeWithSelector(IPoolCore.setCollateralFactor.selector, asset, newCfBps);
        return propose(pool, data);
    }

    function proposeListAsset(address pool, address asset, uint16 cfBps) external onlyMember returns (uint256) {
        bytes memory data = abi.encodeWithSelector(IPoolCore.listAsset.selector, asset, cfBps);
        return propose(pool, data);
    }
}
