// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PrimitiveTypeUtils} from '@iden3/contracts/lib/PrimitiveTypeUtils.sol';
import {ICircuitValidator} from '@iden3/contracts/interfaces/ICircuitValidator.sol';
import {EmbeddedZKPVerifier} from '@iden3/contracts/verifiers/EmbeddedZKPVerifier.sol';
import {IState} from '@iden3/contracts/interfaces/IState.sol';
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract VoteManager is Initializable, ReentrancyGuardTransient, EmbeddedZKPVerifier {
    struct Vote {
        string  name;
        uint256 startDate;
        uint256 endDate;
        uint256 resultsDate;
        uint64  requestId;
        string[] options;
        mapping(string => bool)     existingOptions;
        mapping(string => uint256)  votes;
        mapping(string => string)   nullifiers;
    }

    mapping(string => Vote) private votes;

    modifier validVoteDates(uint256 startDate, uint256 endDate, uint256 resultsDate) {
        _validVoteDates(startDate, endDate, resultsDate);
        _;
    }

    modifier existingVote(string calldata id) {
        _existingVote(id);
        _;
    }

    event VoteCreated(string indexed id, string name);
    event Voted(string indexed voteId);

    function initialize() public {
        super.__EmbeddedZKPVerifier_init(_msgSender(), IState(address(0x0)));
    }

    function _validVoteDates(uint256 startDate, uint256 endDate, uint256 resultsDate) internal pure {
        require(startDate < endDate, "Start date must be before end date");
        require(endDate < resultsDate, "End date must be before results date");
    }

    function _existingVote(string calldata id) internal view {
        require(bytes(votes[id].name).length > 0, "Vote does not exist");
    }

    function _beforeProofSubmit(
        uint64 /* requestId */,
        uint256[] memory inputs,
        ICircuitValidator validator
    ) internal view override {
        // check that challenge input is address of sender
        address addr = PrimitiveTypeUtils.uint256LEToAddress(
            inputs[validator.inputIndexOf('challenge')]
        );
        // this is linking between msg.sender and
        require(_msgSender() == addr, 'address in proof is not a sender address');
    }

    function createVote(
        string calldata id,
        string calldata name,
        uint256 startDate,
        uint256 endDate,
        uint256 resultsDate,
        uint64  requestId,
        string[] memory options
    ) external validVoteDates(startDate, endDate, resultsDate) {
        require(bytes(name).length > 0, "Vote name cannot be empty");
        require(bytes(votes[id].name).length == 0, "Vote already exists");
        require(options.length > 0, "Options cannot be empty");

        votes[id].name = name;
        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
        votes[id].requestId = requestId;
        votes[id].options = options;
        for (uint i = 0; i < options.length; i++) {
            votes[id].existingOptions[options[i]] = true;
        }
        emit VoteCreated(id, name);
    }

    function updateVoteDates(
        string calldata id,
        uint256 startDate,
        uint256 endDate,
        uint256 resultsDate
    ) external validVoteDates(startDate, endDate, resultsDate) existingVote(id) {
        require(block.timestamp < votes[id].startDate - 24 hours, "Too near to vote start date");

        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
    }

    function castVote(string calldata voteId, string calldata optionId, string calldata nullifier) external nonReentrant existingVote(voteId) {
        Vote storage vote = votes[voteId];
        require(block.timestamp >= vote.startDate && block.timestamp <= vote.endDate, "Voting is not active");
        require(vote.existingOptions[optionId], "Invalid option");
        require(bytes(vote.nullifiers[nullifier]).length == 0, "Nullifier already used");

        // Add ZK proof verification
        require(getProofStatus(_msgSender(), vote.requestId).isVerified, "ZK verification failed");

        vote.votes[optionId]++;
        vote.nullifiers[nullifier] = optionId;

        emit Voted(voteId);
    }

    function getVoteResults(string calldata voteId) external view existingVote(voteId) returns (string[] memory options, uint256[] memory voteCounts) {
        Vote storage vote = votes[voteId];
        require(block.timestamp > vote.resultsDate, "Results are not available yet");

        options = vote.options;
        voteCounts = new uint[](vote.options.length);

        for (uint i = 0; i < vote.options.length; i++) {
            voteCounts[i] = vote.votes[vote.options[i]];
        }
    }

    function getOwnVoteInfo(string calldata voteId, string calldata nullifier) external view existingVote(voteId) returns (bool hasVoted, string memory optionVoted) {
        Vote storage vote = votes[voteId];
        require(bytes(vote.nullifiers[nullifier]).length > 0, "Not voted yet");

        hasVoted = true;
        optionVoted = vote.nullifiers[nullifier];
    }
}
