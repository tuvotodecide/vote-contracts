// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract BackVoteManager is Initializable, ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    struct Vote {
        string name;
        uint48 startDate;
        uint48 endDate;
        uint48 resultsDate;
        uint48 totalVoters;
        string[] options;
        mapping(string => bool)    existingOptions;
        mapping(string => bool)    voters;
        mapping(string => uint256) votes;
        mapping(string => string)  nullifiers;
    }

    address private authorizedCaller;
    mapping(string => Vote) private votes;

    modifier validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) {
        _validVoteDates(startDate, endDate, resultsDate);
        _;
    }

    modifier existingVote(string calldata id) {
        _existingVote(id);
        _;
    }

    modifier onlyAuthorizedCaller() {
        _onlyAuthorizedCaller();
        _;
    }

    event VoteCreated(string indexed id, string name);
    event Voted(string indexed voteId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _authorizedCaller) public initializer {
        __Ownable_init(initialOwner);
        authorizedCaller = _authorizedCaller;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    function _validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) internal pure {
        require(startDate < endDate, "Start date must be before end date");
        require(endDate < resultsDate, "End date must be before results date");
    }

    function _existingVote(string calldata id) internal view {
        require(bytes(votes[id].name).length > 0, "Vote does not exist");
    }

    function _onlyAuthorizedCaller() internal view {
        require(msg.sender == authorizedCaller, "Not authorized caller");
    }

    function setAuthorizedCaller(address newCaller) external onlyOwner {
        authorizedCaller = newCaller;
    }

    function getAuthorizedCaller() public view onlyOwner returns (address) {
        return authorizedCaller;
    }

    function createVote(
        string calldata id,
        string calldata name,
        uint48 startDate,
        uint48 endDate,
        uint48 resultsDate,
        string[] memory voters,
        string[] memory options
    ) external validVoteDates(startDate, endDate, resultsDate) onlyAuthorizedCaller {
        require(bytes(name).length > 0, "Vote name cannot be empty");
        require(bytes(votes[id].name).length == 0, "Vote already exists");
        require(options.length > 0, "Options cannot be empty");

        votes[id].name = name;
        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
        votes[id].totalVoters = uint48(voters.length);
        votes[id].options = options;
        for (uint i = 0; i < voters.length; i++) {
            votes[id].voters[voters[i]] = true;
        }
        for (uint i = 0; i < options.length; i++) {
            votes[id].existingOptions[options[i]] = true;
        }
        emit VoteCreated(id, name);
    }

    function updateVoteDates(
        string calldata id,
        uint48 startDate,
        uint48 endDate,
        uint48 resultsDate
    ) external validVoteDates(startDate, endDate, resultsDate) existingVote(id) onlyAuthorizedCaller {
        require(block.timestamp < votes[id].startDate - 24 hours, "Too near to vote start date");

        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
    }

    function castVote(string calldata voteId, string calldata optionId, string calldata nullifier) external nonReentrant existingVote(voteId) onlyAuthorizedCaller {
        Vote storage vote = votes[voteId];
        require(vote.voters[nullifier], "Not eligible to vote");
        require(block.timestamp >= vote.startDate && block.timestamp <= vote.endDate, "Voting is not active");
        require(vote.existingOptions[optionId], "Invalid option");
        require(bytes(vote.nullifiers[nullifier]).length == 0, "Nullifier already used");

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

    function getVoteInfo(string calldata voteId) external view existingVote(voteId) returns (string memory name, uint48 startDate, uint48 endDate, uint48 resultsDate, uint48 totalVoters, string[] memory options) {
        Vote storage vote = votes[voteId];
        name = vote.name;
        startDate = vote.startDate;
        endDate = vote.endDate;
        resultsDate = vote.resultsDate;
        totalVoters = vote.totalVoters;
        options = vote.options;
    }

    function getOwnVoteInfo(string calldata voteId, string calldata nullifier) external view existingVote(voteId) returns (bool hasVoted, string memory optionVoted) {
        Vote storage vote = votes[voteId];
        require(bytes(vote.nullifiers[nullifier]).length > 0, "Not voted yet");

        hasVoted = true;
        optionVoted = vote.nullifiers[nullifier];
    }
}
