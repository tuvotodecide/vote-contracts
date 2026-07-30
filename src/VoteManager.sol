// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TVDElectoralCredits} from "./tvd-token/TVDElectoralCredits.sol";
import {TVDToken} from "./tvd-token/TVDToken.sol";

/// @title VoteManager
/// @notice Registers institutions and their votes, records anonymous vote casts, and pays out
/// TVD token rewards for eligible votes.
/// @dev Upgradeable (UUPS) contract. Institutions are permissioned entities that create and
/// manage their own votes; a single `authorizedCaller` relays vote casts on behalf of voters,
/// keeping voter identities off-chain/anonymous.
contract VoteManager is Initializable, ReentrancyGuardTransient, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Stores all data for a single vote event.
    /// @dev Mapping fields cannot be copied or deleted; disabling a vote is done via `voteStates`
    /// rather than clearing this struct.
    struct Vote {
        /// @notice Human-readable name of the vote.
        string name;
        /// @notice Id of the institution that owns this vote.
        string institutionId;
        /// @notice Timestamp from which votes may be cast.
        uint48 startDate;
        /// @notice Timestamp after which votes may no longer be cast.
        uint48 endDate;
        /// @notice Timestamp from which results become publicly queryable.
        uint48 resultsDate;
        /// @notice Number of voters enabled/allotted for this vote (used to top up credits).
        uint48 totalVotersCount;
        /// @notice Merkle root(s) of the set of voters enabled to participate.
        uint256 totalVoters;
        /// @notice Ordered list of selectable option ids.
        string[] options;
        /// @notice Quick lookup of whether a given option id is valid for this vote.
        mapping(string => bool) existingOptions;
        /// @notice Tally of votes received per option id.
        mapping(string => uint256) votes;
        /// @notice Maps a spent nullifier to the option it voted for; used to block double voting.
        mapping(uint256 => string) nullifiers;
        /// @notice Marks a reward hash as already claimed, preventing double claims.
        mapping(uint256 => bool) alreadyRewarded;
    }

    /// @notice Represents an organization allowed to create and manage its own votes.
    struct Institution {
        /// @notice Unique id of the institution.
        string id;
        /// @notice Address with full administrative rights over the institution.
        address admin;
        /// @notice Addresses (besides the admin) allowed to act on behalf of the institution.
        mapping(address => bool) authorizedAddresses;
    }

    /// @notice Sole address allowed to cast votes on behalf of voters.
    address private authorizedCaller;
    /// @notice All votes ever created, keyed by vote id.
    mapping(uint256 => Vote) private votes;
    /// @notice State of each vote: 0 = active, 1 = disabled.
    mapping(uint256 => uint8) private voteStates; // 0 = active, 1 = disabled
    /// @notice All institutions ever created, keyed by institution id.
    mapping(string => Institution) private institutions;

    /// @notice Electoral credits contract used to top up and consume per-vote voting credits.
    TVDElectoralCredits private creditsContract;
    /// @notice ERC20 token distributed as a reward for eligible votes.
    TVDToken private tvdToken;

    /// @notice Amount of `tvdToken` paid out per eligible reward claim.
    uint256 public tvdPerVote;

    /// @notice Reverts unless `startDate < endDate < resultsDate`.
    modifier validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) {
        _validVoteDates(startDate, endDate, resultsDate);
        _;
    }

    /// @notice Reverts unless a vote with the given `id` has been created.
    modifier existingVote(uint256 id) {
        _existingVote(id);
        _;
    }

    /// @notice Reverts unless the vote with the given `id` has not been disabled.
    modifier activeVote(uint256 id) {
        _activeVote(id);
        _;
    }

    /// @notice Reverts unless the vote with the given `id` has passed its end date.
    modifier voteEnded(uint256 id) {
        _voteEnded(id);
        _;
    }

    /// @notice Reverts unless the caller is the configured `authorizedCaller`.
    modifier onlyAuthorizedCaller() {
        _onlyAuthorizedCaller();
        _;
    }

    /// @notice Reverts unless an institution with the given `id` exists.
    modifier existingInstitution(string calldata id) {
        _existingInstitution(id);
        _;
    }

    /// @notice Reverts unless the caller is the admin of the institution with the given `id`.
    modifier onlyInstitutionAdmin(string calldata id) {
        _onlyInstitutionAdmin(id);
        _;
    }

    /// @notice Reverts unless the institution exists and the caller is its admin or an authorized address.
    modifier onlyAuthorizedInInstitution(string memory institutionId) {
        _onlyAuthorizedInInstitution(institutionId);
        _;
    }

    /// @notice Emitted when a new vote is created.
    event VoteCreated(uint256 indexed id, string name);
    /// @notice Emitted when a vote is successfully cast.
    event Voted(uint256 indexed voteId);
    /// @notice Emitted when a new institution is created.
    event InstitutionCreated(string indexed id, address admin);
    /// @notice Emitted when an institution is deleted.
    event InstitutionDeleted(string indexed id);
    /// @notice Emitted when an institution's admin address is changed.
    event InstitutionAdminChanged(string indexed id, address newAdmin);
    /// @notice Emitted when a vote reward is successfully claimed.
    event Rewarded(uint256 indexed id, address indexed recipient);

    /// @notice Disables initializers on the implementation contract so it cannot be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy, setting the owner, authorized caller, and dependent contracts.
    /// @dev Replaces the constructor for upgradeable contracts; can only run once.
    /// @param initialOwner Address granted contract ownership (upgrade/admin rights).
    /// @param _authorizedCaller Address allowed to cast votes on behalf of voters.
    /// @param _creditsContract Address of the TVDElectoralCredits contract.
    /// @param _tvdToken Address of the TVD ERC20 token used for rewards.
    function initialize(address initialOwner, address _authorizedCaller, address _creditsContract, address _tvdToken)
        public
        initializer
    {
        __Ownable_init(initialOwner);
        authorizedCaller = _authorizedCaller;
        creditsContract = TVDElectoralCredits(_creditsContract);
        tvdToken = TVDToken(_tvdToken);
    }

    /// @notice Authorizes a UUPS upgrade; restricted to the contract owner.
    /// @param newImplementation Address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Validates the chronological ordering of a vote's lifecycle dates.
    function _validVoteDates(uint48 startDate, uint48 endDate, uint48 resultsDate) internal pure {
        require(startDate < endDate, "Start date must be before end date");
        require(endDate < resultsDate, "End date must be before results date");
    }

    /// @notice Checks that a vote with the given id has been created.
    function _existingVote(uint256 id) internal view {
        require(bytes(votes[id].name).length > 0, "Vote does not exist");
    }

    /// @notice Checks that a vote has not been disabled.
    function _activeVote(uint256 id) internal view {
        require(voteStates[id] == 0, "Vote is not active");
    }

    /// @notice Checks that a vote's end date has passed.
    function _voteEnded(uint256 id) internal view {
        require(block.timestamp > votes[id].endDate, "Vote has not ended yet");
    }

    /// @notice Checks that the caller is the configured authorized caller.
    function _onlyAuthorizedCaller() internal view {
        require(msg.sender == authorizedCaller, "Not authorized caller");
    }

    /// @notice Checks that an institution with the given id exists.
    function _existingInstitution(string calldata id) internal view {
        require(institutions[id].admin != address(0), "Institution does not exist");
    }

    /// @notice Checks that the caller is the admin of the given institution.
    function _onlyInstitutionAdmin(string calldata id) internal view {
        require(msg.sender == institutions[id].admin, "Not institution admin");
    }

    /// @notice Checks that the given institution exists and the caller is its admin or an authorized address.
    function _onlyAuthorizedInInstitution(string memory institutionId) internal view {
        require(institutions[institutionId].admin != address(0), "Institution does not exist");
        require(
            msg.sender == institutions[institutionId].admin
                || institutions[institutionId].authorizedAddresses[msg.sender],
            "Not authorized in institution"
        );
    }

    /// @notice Sets the address allowed to cast votes on behalf of voters.
    /// @param newCaller New authorized caller address.
    function setAuthorizedCaller(address newCaller) external onlyOwner {
        authorizedCaller = newCaller;
    }

    /// @notice Returns the current authorized caller address.
    /// @return The address allowed to cast votes on behalf of voters.
    function getAuthorizedCaller() public view onlyOwner returns (address) {
        return authorizedCaller;
    }

    /// @notice Updates the TVDElectoralCredits contract used to top up and consume voting credits.
    /// @param newCreditsContract Address of the new TVDElectoralCredits contract.
    function setCreditsContract(address newCreditsContract) external onlyOwner {
        require(newCreditsContract != address(0), "Credits contract cannot be zero address");
        creditsContract = TVDElectoralCredits(newCreditsContract);
    }

    /// @notice Sets the TVD token amount paid out per eligible vote reward claim.
    /// @param newTvdPerVote New reward amount, in `tvdToken` units.
    function setTvdPerVote(uint256 newTvdPerVote) external onlyOwner {
        tvdPerVote = newTvdPerVote;
    }

    /// @notice Creates a new institution with the given id and admin.
    /// @dev Only callable by the authorized caller.
    /// @param id Unique, non-empty id for the institution.
    /// @param admin Address to set as the institution's admin.
    function createInstitution(string calldata id, address admin) external onlyAuthorizedCaller {
        require(bytes(id).length > 0, "Institution id cannot be empty");
        require(institutions[id].admin == address(0), "Institution already exists");
        require(admin != address(0), "Admin cannot be zero address");

        institutions[id].id = id;
        institutions[id].admin = admin;

        emit InstitutionCreated(id, admin);
    }

    /// @notice Deletes an existing institution.
    /// @dev Only callable by the authorized caller. Mappings can't be deleted in Solidity, so
    /// `authorizedAddresses` persist if the id is reused later.
    /// @param id Id of the institution to delete.
    // Mappings can't be deleted in Solidity, so authorizedAddresses persist if the id is reused later.
    function deleteInstitution(string calldata id) external existingInstitution(id) onlyAuthorizedCaller {
        delete institutions[id];
        emit InstitutionDeleted(id);
    }

    /// @notice Grants an address permission to act on behalf of an institution.
    /// @dev Only callable by the institution's admin.
    /// @param id Id of the institution.
    /// @param addr Address to authorize.
    function addAuthorizedAddress(string calldata id, address addr)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        require(addr != address(0), "Address cannot be zero address");
        institutions[id].authorizedAddresses[addr] = true;
    }

    /// @notice Revokes an address's permission to act on behalf of an institution.
    /// @dev Only callable by the institution's admin.
    /// @param id Id of the institution.
    /// @param addr Address to deauthorize.
    function removeAuthorizedAddress(string calldata id, address addr)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        institutions[id].authorizedAddresses[addr] = false;
    }

    /// @notice Transfers admin rights of an institution to a new address.
    /// @dev Only callable by the current institution admin.
    /// @param id Id of the institution.
    /// @param newAdmin Address to become the new admin.
    function changeInstitutionAdmin(string calldata id, address newAdmin)
        external
        existingInstitution(id)
        onlyInstitutionAdmin(id)
    {
        require(newAdmin != address(0), "New admin cannot be zero address");
        institutions[id].admin = newAdmin;
        emit InstitutionAdminChanged(id, newAdmin);
    }

    /// @notice Returns the admin address of an institution.
    /// @param id Id of the institution.
    /// @return Address of the institution's admin.
    function getInstitutionAdmin(string calldata id) external view existingInstitution(id) returns (address) {
        return institutions[id].admin;
    }

    /// @notice Checks whether an address is authorized to act on behalf of an institution.
    /// @param id Id of the institution.
    /// @param addr Address to check.
    /// @return True if `addr` is authorized (not necessarily the admin).
    function isAuthorizedAddress(string calldata id, address addr)
        external
        view
        existingInstitution(id)
        returns (bool)
    {
        return institutions[id].authorizedAddresses[addr];
    }

    /// @notice Creates a new vote owned by an institution and tops up voting credits for it.
    /// @dev Only callable by the institution's admin or an authorized address. Dates must satisfy
    /// `startDate < endDate < resultsDate`.
    /// @param id Unique id for the vote.
    /// @param institutionId Id of the institution the vote belongs to.
    /// @param name Human-readable name of the vote.
    /// @param startDate Timestamp from which votes may be cast.
    /// @param endDate Timestamp after which votes may no longer be cast.
    /// @param resultsDate Timestamp from which results become publicly queryable.
    /// @param enabledVotersCount Number of voters enabled to participate; used to top up credits.
    /// @param enabledVotersMkRoot Merkle root(s) of the set of voters enabled to participate.
    /// @param options List of selectable option ids; must be non-empty.
    function createVote(
        uint256 id,
        string calldata institutionId,
        string calldata name,
        uint48 startDate,
        uint48 endDate,
        uint48 resultsDate,
        uint48 enabledVotersCount,
        uint256 enabledVotersMkRoot,
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
        votes[id].totalVotersCount = enabledVotersCount;
        votes[id].totalVoters = enabledVotersMkRoot;
        votes[id].options = options;
        for (uint256 i = 0; i < options.length; i++) {
            votes[id].existingOptions[options[i]] = true;
        }

        creditsContract.topUp(msg.sender, id, enabledVotersCount);
        emit VoteCreated(id, name);
    }

    /// @notice Updates the lifecycle dates of an existing, active vote.
    /// @dev Only callable by the owning institution's admin or an authorized address, and only
    /// more than 24 hours before the vote's current start date.
    /// @param id Id of the vote to update.
    /// @param startDate New timestamp from which votes may be cast.
    /// @param endDate New timestamp after which votes may no longer be cast.
    /// @param resultsDate New timestamp from which results become publicly queryable.
    function updateVoteDates(uint256 id, uint48 startDate, uint48 endDate, uint48 resultsDate)
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

    /// @notice Disables an active vote, preventing further casts.
    /// @dev Only callable by the owning institution's admin or an authorized address. Irreversible.
    /// @param id Id of the vote to disable.
    function disableVote(uint256 id) external activeVote(id) onlyAuthorizedInInstitution(votes[id].institutionId) {
        voteStates[id] = 1;
    }

    /// @notice Casts an anonymous vote for a given option.
    /// @dev Only callable by the authorized caller, which relays votes on behalf of voters so their
    /// identity is not exposed on-chain. Reverts if the vote is not currently open, the option is
    /// invalid, or the nullifier was already used. Consumes one voting credit.
    /// @param optionId Id of the option being voted for; must be one of the vote's registered options.
    /// @param voteId Id of the vote being cast in.
    /// @param voteNullifier Unique nullifier for this voter/vote pair, preventing double voting.
    function castVote(string calldata optionId, uint256 voteId, uint256 voteNullifier)
        external
        nonReentrant
        existingVote(voteId)
        activeVote(voteId)
        onlyAuthorizedCaller
    {
        Vote storage vote = votes[voteId];
        require(block.timestamp >= vote.startDate && block.timestamp <= vote.endDate, "Voting is not active");
        require(vote.existingOptions[optionId], "Invalid option");
        require(bytes(vote.nullifiers[voteNullifier]).length == 0, "Nullifier already used");

        vote.votes[optionId]++;
        vote.nullifiers[voteNullifier] = optionId;
        creditsContract.consumeVote(voteId);

        emit Voted(voteId);
    }

    /// @notice Claims the TVD token reward for a vote, on behalf of a voter identified by `rewardHash`.
    /// @dev Only callable by the authorized caller, and only once the vote's end date has passed.
    /// @param voteId Id of the vote being claimed against.
    /// @param rewardHash Hash identifying the reward claim; used to prevent double claims.
    /// @param recipient Address to receive the reward.
    function claimVoteReward(uint256 voteId, uint256 rewardHash, address recipient)
        external
        nonReentrant
        existingVote(voteId)
        voteEnded(voteId)
        onlyAuthorizedCaller
    {
        Vote storage vote = votes[voteId];
        require(!vote.alreadyRewarded[rewardHash], "Already rewarded");
        require(tvdToken.balanceOf(address(this)) >= tvdPerVote, "Insufficient contract balance");

        vote.alreadyRewarded[rewardHash] = true;
        tvdToken.setApplyLockup(recipient, true);
        bool success = tvdToken.transfer(recipient, tvdPerVote);
        require(success, "Reward transfer failed");
        emit Rewarded(voteId, recipient);
    }

    /// @notice Returns the final tally of votes per option for a finished vote.
    /// @dev Reverts if `resultsDate` has not yet been reached.
    /// @param voteId Id of the vote to query.
    /// @return options List of option ids, in the vote's original order.
    /// @return voteCounts Vote counts, aligned index-for-index with `options`.
    function getVoteResults(uint256 voteId)
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

    /// @notice Returns the general metadata of a vote.
    /// @param voteId Id of the vote to query.
    /// @return name Human-readable name of the vote.
    /// @return startDate Timestamp from which votes may be cast.
    /// @return endDate Timestamp after which votes may no longer be cast.
    /// @return resultsDate Timestamp from which results become publicly queryable.
    /// @return totalVoters Number of voters enabled to participate.
    /// @return totalVotersMkRoot Merkle root of total voters.
    /// @return options List of selectable option ids.
    function getVoteInfo(uint256 voteId)
        external
        view
        existingVote(voteId)
        returns (
            string memory name,
            uint48 startDate,
            uint48 endDate,
            uint48 resultsDate,
            uint48 totalVoters,
            uint256 totalVotersMkRoot,
            string[] memory options
        )
    {
        Vote storage vote = votes[voteId];
        name = vote.name;
        startDate = vote.startDate;
        endDate = vote.endDate;
        resultsDate = vote.resultsDate;
        totalVoters = vote.totalVotersCount;
        totalVotersMkRoot = vote.totalVoters;
        options = vote.options;
    }

    /// @notice Returns the id of the institution that owns a vote.
    /// @param voteId Id of the vote to query.
    /// @return Id of the owning institution.
    function getVoteInstitutionId(uint256 voteId) external view existingVote(voteId) returns (string memory) {
        return votes[voteId].institutionId;
    }

    /// @notice Checks whether a given nullifier has voted in a vote, and which option it chose.
    /// @dev Reverts if the nullifier has not voted yet; callers should treat that as "not voted".
    /// @param voteId Id of the vote to query.
    /// @param nullifier Nullifier to look up.
    /// @return hasVoted Always true when this function does not revert.
    /// @return optionVoted Id of the option the nullifier voted for.
    function getOwnVoteInfo(uint256 voteId, uint256 nullifier)
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

    /// @notice Checks whether a reward has already been claimed for a vote.
    /// @param voteId Id of the vote to query.
    /// @param rewardHash Hash identifying the reward claim, as passed to `claimVoteReward`.
    /// @return hasReceivedReward True if `rewardHash` has already been claimed for `voteId`.
    function hasReceivedReward(uint256 voteId, uint256 rewardHash) external view returns (bool hasReceivedReward) {
        return votes[voteId].alreadyRewarded[rewardHash];
    }
}
