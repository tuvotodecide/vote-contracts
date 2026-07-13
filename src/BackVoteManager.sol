// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract BackVoteManager is Initializable, ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    struct Vote {
        string name;
        string institutionId;
        uint48 startDate;
        uint48 endDate;
        uint48 resultsDate;
        uint48 totalVoters;
        string[] options;
        mapping(string => bool) existingOptions;
        mapping(string => bool) voters;
        mapping(string => uint256) votes;
        mapping(string => string) nullifiers;
    }

    struct Institution {
        string id;
        address admin;
        mapping(address => bool) authorizedAddresses;
    }

    address private authorizedCaller;
    mapping(string => Vote) private votes;
    mapping(string => uint8) private voteStates; // 0 = active, 1 = disabled
    mapping(string => Institution) private institutions;

    modifier validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) {
        _validVoteDates(startDate, endDate, resultsDate);
        _;
    }

    modifier existingVote(string calldata id) {
        _existingVote(id);
        _;
    }

    modifier activeVote(string calldata id) {
        _activeVote(id);
        _;
    }

    modifier onlyAuthorizedCaller() {
        _onlyAuthorizedCaller();
        _;
    }

    modifier existingInstitution(string calldata id) {
        _existingInstitution(id);
        _;
    }

    modifier onlyInstitutionAdmin(string calldata id) {
        _onlyInstitutionAdmin(id);
        _;
    }

    modifier onlyAuthorizedInInstitution(string memory institutionId) {
        _onlyAuthorizedInInstitution(institutionId);
        _;
    }

    event VoteCreated(string indexed id, string name);
    event Voted(string indexed voteId);
    event InstitutionCreated(string indexed id, address admin);
    event InstitutionDeleted(string indexed id);
    event InstitutionAdminChanged(string indexed id, address newAdmin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _authorizedCaller) public initializer {
        __Ownable_init(initialOwner);
        authorizedCaller = _authorizedCaller;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) internal pure {
        require(startDate < endDate, "Start date must be before end date");
        require(endDate < resultsDate, "End date must be before results date");
    }

    function _existingVote(string calldata id) internal view {
        require(bytes(votes[id].name).length > 0, "Vote does not exist");
    }

    function _activeVote(string calldata id) internal view {
        require(voteStates[id] == 0, "Vote is not active");
    }

    function _onlyAuthorizedCaller() internal view {
        require(msg.sender == authorizedCaller, "Not authorized caller");
    }

    function _existingInstitution(string calldata id) internal view {
        require(institutions[id].admin != address(0), "Institution does not exist");
    }

    function _onlyInstitutionAdmin(string calldata id) internal view {
        require(msg.sender == institutions[id].admin, "Not institution admin");
    }

    function _onlyAuthorizedInInstitution(string memory institutionId) internal view {
        require(institutions[institutionId].admin != address(0), "Institution does not exist");
        require(
            msg.sender == institutions[institutionId].admin
                || institutions[institutionId].authorizedAddresses[msg.sender],
            "Not authorized in institution"
        );
    }

    function setAuthorizedCaller(address newCaller) external onlyOwner {
        authorizedCaller = newCaller;
    }

    function getAuthorizedCaller() public view onlyOwner returns (address) {
        return authorizedCaller;
    }

    function createInstitution(string calldata id, address admin) external onlyAuthorizedCaller {
        require(bytes(id).length > 0, "Institution id cannot be empty");
        require(institutions[id].admin == address(0), "Institution already exists");
        require(admin != address(0), "Admin cannot be zero address");

        institutions[id].id = id;
        institutions[id].admin = admin;

        emit InstitutionCreated(id, admin);
    }

    // Mappings can't be deleted in Solidity, so authorizedAddresses persist if the id is reused later.
    function deleteInstitution(string calldata id) external existingInstitution(id) onlyAuthorizedCaller {
        delete institutions[id];
        emit InstitutionDeleted(id);
    }

    function addAuthorizedAddress(string calldata id, address addr)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        require(addr != address(0), "Address cannot be zero address");
        institutions[id].authorizedAddresses[addr] = true;
    }

    function removeAuthorizedAddress(string calldata id, address addr)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        institutions[id].authorizedAddresses[addr] = false;
    }

    function changeInstitutionAdmin(string calldata id, address newAdmin)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        require(newAdmin != address(0), "New admin cannot be zero address");
        institutions[id].admin = newAdmin;
        emit InstitutionAdminChanged(id, newAdmin);
    }

    function getInstitutionAdmin(string calldata id) external view existingInstitution(id) returns (address) {
        return institutions[id].admin;
    }

    function isAuthorizedAddress(string calldata id, address addr)
        external
        view
        existingInstitution(id)
        returns (bool)
    {
        return institutions[id].authorizedAddresses[addr];
    }

    function createVote(
        string calldata id,
        string calldata institutionId,
        string calldata name,
        uint48 startDate,
        uint48 endDate,
        uint48 resultsDate,
        string[] memory voters,
        string[] memory options
    ) external validVoteDates(startDate, endDate, resultsDate) onlyAuthorizedInInstitution(institutionId) {
        require(bytes(name).length > 0, "Vote name cannot be empty");
        require(bytes(votes[id].name).length == 0, "Vote already exists");
        require(options.length > 0, "Options cannot be empty");

        votes[id].name = name;
        votes[id].institutionId = institutionId;
        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
        votes[id].totalVoters = uint48(voters.length);
        votes[id].options = options;
        for (uint256 i = 0; i < voters.length; i++) {
            votes[id].voters[voters[i]] = true;
        }
        for (uint256 i = 0; i < options.length; i++) {
            votes[id].existingOptions[options[i]] = true;
        }
        emit VoteCreated(id, name);
    }

    function updateVoteDates(string calldata id, uint48 startDate, uint48 endDate, uint48 resultsDate)
        external
        validVoteDates(startDate, endDate, resultsDate)
        existingVote(id)
        activeVote(id)
        onlyAuthorizedInInstitution(votes[id].institutionId)
    {
        require(block.timestamp < votes[id].startDate - 24 hours, "Too near to vote start date");

        votes[id].startDate = startDate;
        votes[id].endDate = endDate;
        votes[id].resultsDate = resultsDate;
    }

    function addNewVoters(string calldata id, string[] memory newVoters)
        external
        existingVote(id)
        activeVote(id)
        onlyAuthorizedCaller
    {
        Vote storage vote = votes[id];
        require(block.timestamp < vote.endDate, "Too late to add voters");

        for (uint256 i = 0; i < newVoters.length; i++) {
            if (!vote.voters[newVoters[i]]) {
                vote.voters[newVoters[i]] = true;
                vote.totalVoters++;
            }
        }
    }

    function disableVote(string calldata id)
        external
        activeVote(id)
        onlyAuthorizedInInstitution(votes[id].institutionId)
    {
        voteStates[id] = 1;
    }

    function castVote(string calldata voteId, string calldata optionId, string calldata nullifier)
        external
        nonReentrant
        existingVote(voteId)
        activeVote(voteId)
        onlyAuthorizedCaller
    {
        Vote storage vote = votes[voteId];
        require(vote.voters[nullifier], "Not eligible to vote");
        require(block.timestamp >= vote.startDate && block.timestamp <= vote.endDate, "Voting is not active");
        require(vote.existingOptions[optionId], "Invalid option");
        require(bytes(vote.nullifiers[nullifier]).length == 0, "Nullifier already used");

        vote.votes[optionId]++;
        vote.nullifiers[nullifier] = optionId;

        emit Voted(voteId);
    }

    function getVoteResults(string calldata voteId)
        external
        view
        existingVote(voteId)
        returns (string[] memory options, uint256[] memory voteCounts)
    {
        Vote storage vote = votes[voteId];
        require(block.timestamp > vote.resultsDate, "Results are not available yet");

        options = vote.options;
        voteCounts = new uint256[](vote.options.length);

        for (uint256 i = 0; i < vote.options.length; i++) {
            voteCounts[i] = vote.votes[vote.options[i]];
        }
    }

    function getVoteInfo(string calldata voteId)
        external
        view
        existingVote(voteId)
        returns (
            string memory name,
            uint48 startDate,
            uint48 endDate,
            uint48 resultsDate,
            uint48 totalVoters,
            string[] memory options
        )
    {
        Vote storage vote = votes[voteId];
        name = vote.name;
        startDate = vote.startDate;
        endDate = vote.endDate;
        resultsDate = vote.resultsDate;
        totalVoters = vote.totalVoters;
        options = vote.options;
    }

    function getVoteInstitutionId(string calldata voteId) external view existingVote(voteId) returns (string memory) {
        return votes[voteId].institutionId;
    }

    function getOwnVoteInfo(string calldata voteId, string calldata nullifier)
        external
        view
        existingVote(voteId)
        returns (bool hasVoted, string memory optionVoted)
    {
        Vote storage vote = votes[voteId];
        require(bytes(vote.nullifiers[nullifier]).length > 0, "Not voted yet");

        hasVoted = true;
        optionVoted = vote.nullifiers[nullifier];
    }
}
