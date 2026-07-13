// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVestingProvider} from "./IVestingProvider.sol";

/**
 * @title  TVDIncentiveCampaigns
 * @notice Operator-driven TVD incentive distribution with a time-locked
 *         assignment window and a post-lock claim phase.
 *
 * ── Lifecycle ────────────────────────────────────────────────────────
 *
 *  1. CREATE  (owner)
 *     Owner calls createCampaign() to register a new campaign, specifying
 *     the per-wallet TVD amount, active window, cap, and the funding wallet.
 *     The funding wallet must pre-approve this contract for the full budget.
 *
 *  2. GIVE INCENTIVE  (operator)
 *     During the active window (start ≤ now < start + duration):
 *       • Tokens are ASSIGNED to the recipient (no immediate transfer).
 *     After the active window has ended (now ≥ start + duration):
 *       • Tokens are TRANSFERRED directly from the funding wallet.
 *     The campaign must not be paused in either case.
 *
 *  3. RELEASE  (recipient)
 *     After block.timestamp ≥ campaign.start + campaign.duration, a
 *     recipient who was assigned tokens during the active window may
 *     call release() to pull them from the funding wallet.
 *
 *  4. PAUSE / UNPAUSE  (owner)
 *     Owner may pause a campaign at any time to halt new incentive grants
 *     without affecting already-assigned balances.
 *
 * ── Security notes ───────────────────────────────────────────────────
 *  • Only one grant per wallet per campaign (hasReceived guard).
 *  • CEI pattern: state is updated before external token calls.
 *  • The funding wallet bears responsibility for maintaining sufficient
 *    allowance and balance for the lifetime of the campaign.
 */
contract TVDIncentiveCampaigns is Ownable, ReentrancyGuard, IVestingProvider {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────

    /// @notice Default campaign duration when none is specified at creation.
    uint256 public constant DEFAULT_DURATION = 365 days;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract used for all transfers.
    IERC20 public immutable token;

    /// @notice Address authorised to call giveIncentive().
    address public operator;

    /// @notice Auto-incrementing campaign counter; also serves as the next ID.
    uint256 public campaignCount;

    struct IncentiveCampaign {
        /// @notice TVD amount (wei) distributed to each eligible wallet.
        uint256 incentiveAmountPerWallet;
        /// @notice Unix timestamp when the campaign becomes active.
        uint256 start;
        /// @notice Active-window duration in seconds (default: DEFAULT_DURATION = 365 days).
        ///         Assigned tokens can be released only after start + duration.
        uint256 duration;
        /// @notice When true, giveIncentive() is blocked for this campaign.
        ///         Does NOT affect already-assigned balances.
        bool isPaused;
        /// @notice Maximum number of wallets that may receive the incentive.
        ///         Set to 0 for unlimited.
        uint256 maxWallets;
        /// @notice Source wallet for all token transfers and assignments.
        ///         IMPORTANT: this wallet must call token.approve(address(this), budget)
        ///         before any incentive can be given or claimed.
        address fundingWallet;
        /// @notice Running count of wallets that have already received the incentive.
        uint256 walletsCount;
    }

    /// @notice All campaigns indexed by their ID (0-based, auto-incremented).
    mapping(uint256 => IncentiveCampaign) public campaigns;

    /// @notice campaignId => recipient => TVD assigned but not yet transferred.
    mapping(uint256 => mapping(address => uint256)) public campaignBalance;

    /// @notice campaignId => recipient => true once the wallet has received
    ///         (or been assigned) an incentive for this campaign.
    mapping(uint256 => mapping(address => bool)) public hasReceived;

    /// @notice Institution => TVD held in this contract from creditRefund returns.
    mapping(address => uint256) public refundedHolding;

    /// @notice TVDElectoralCredits contract authorised to call withdrawFor / creditRefund.
    address public creditsContract;

    /// @notice Unix timestamp when the token lock period begins.
    uint256 public blockStartTime;

    /// @notice Duration of the token lock in seconds (default: 365 days).
    ///         Assigned tokens cannot be released before blockStartTime + blockDuration.
    uint256 public blockDuration;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event CampaignCreated(
        uint256 indexed campaignId,
        uint256 incentiveAmountPerWallet,
        uint256 start,
        uint256 duration,
        uint256 maxWallets,
        address indexed fundingWallet
    );
    event IncentiveAssigned(uint256 indexed campaignId, address indexed recipient, uint256 amount);
    event IncentiveTransferred(uint256 indexed campaignId, address indexed recipient, uint256 amount);
    event IncentiveClaimed(uint256 indexed campaignId, address indexed recipient, uint256 amount);
    event CampaignPauseSet(uint256 indexed campaignId, bool isPaused);
    event OperatorSet(address indexed oldOperator, address indexed newOperator);
    event CreditsContractSet(address indexed oldContract, address indexed newContract);
    event InstitutionTokensWithdrawn(address indexed institution, uint256 amount);
    event InstitutionTokensRefunded(address indexed institution, uint256 amount);
    event RefundClaimed(address indexed institution, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(msg.sender == operator, "TVDIncentive: caller is not operator");
        _;
    }

    modifier campaignExists(uint256 campaignId) {
        require(campaignId < campaignCount, "TVDIncentive: campaign does not exist");
        _;
    }

    modifier onlyCreditsContract() {
        require(msg.sender == creditsContract, "TVDIncentive: caller is not credits contract");
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token    TVDToken address.
     * @param _admin    Owner / admin multisig (Ownable).
     * @param _operator Address authorised to grant incentives.
     */
    constructor(address _token, address _admin, address _operator, uint256 _blockStartTime) Ownable(_admin) {
        require(_token != address(0), "TVDIncentive: invalid token");
        require(_operator != address(0), "TVDIncentive: invalid operator");
        require(_blockStartTime > 0, "TVDIncentive: invalid blockStartTime");

        token = IERC20(_token);
        operator = _operator;
        blockStartTime = _blockStartTime;
        blockDuration = 365 days;
    }

    // ──────────────────────────────────────────────────────────────────
    // Owner — configuration
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Replace the authorised operator address.
     * @param _operator New operator address.
     */
    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "TVDIncentive: invalid operator");
        emit OperatorSet(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Set or update the authorised TVDElectoralCredits contract.
     * @param _creditsContract Address of the TVDElectoralCredits contract.
     */
    function setCreditsContract(address _creditsContract) external onlyOwner {
        require(_creditsContract != address(0), "TVDIncentive: invalid address");
        emit CreditsContractSet(creditsContract, _creditsContract);
        creditsContract = _creditsContract;
    }

    /**
     * @notice Create a new incentive campaign.
     *
     * @dev    Pass 0 for `duration` to use the DEFAULT_DURATION (365 days).
     *         The fundingWallet must approve this contract for at least
     *         incentiveAmountPerWallet * maxWallets TVD before any grants
     *         can be processed.
     *
     * @param incentiveAmountPerWallet TVD (wei) each eligible wallet receives.
     * @param start                    Unix timestamp when the campaign becomes active.
     * @param duration                 Active-window length in seconds (0 → 365 days).
     * @param maxWallets               Cap on eligible wallets (0 = unlimited).
     * @param fundingWallet            Wallet that provides the tokens.
     *                                 Must pre-approve this contract via token.approve().
     * @return campaignId              ID assigned to the new campaign.
     */
    function createCampaign(
        uint256 incentiveAmountPerWallet,
        uint256 start,
        uint256 duration,
        uint256 maxWallets,
        address fundingWallet
    ) external onlyOwner returns (uint256 campaignId) {
        require(incentiveAmountPerWallet > 0, "TVDIncentive: incentive must be > 0");
        require(start > 0, "TVDIncentive: invalid start time");
        require(fundingWallet != address(0), "TVDIncentive: invalid funding wallet");

        uint256 effectiveDuration = duration == 0 ? DEFAULT_DURATION : duration;

        // Enforce single-active-campaign constraint: the new window must not
        // overlap with any existing campaign's window (regardless of pause state).
        uint256 newEnd = start + effectiveDuration;
        for (uint256 i = 0; i < campaignCount; i++) {
            IncentiveCampaign storage existing = campaigns[i];
            uint256 existingEnd = existing.start + existing.duration;
            require(
                newEnd <= existing.start || start >= existingEnd,
                "TVDIncentive: time window overlaps with an existing campaign"
            );
        }

        campaignId = campaignCount++;

        campaigns[campaignId] = IncentiveCampaign({
            incentiveAmountPerWallet: incentiveAmountPerWallet,
            start: start,
            duration: effectiveDuration,
            isPaused: false,
            maxWallets: maxWallets,
            fundingWallet: fundingWallet,
            walletsCount: 0
        });

        token.safeTransferFrom(fundingWallet, address(this), incentiveAmountPerWallet * maxWallets);

        emit CampaignCreated(campaignId, incentiveAmountPerWallet, start, effectiveDuration, maxWallets, fundingWallet);
    }

    /**
     * @notice Pause or unpause an incentive campaign.
     *         Pausing blocks new incentive grants but does not affect
     *         already-assigned balances or the release() function.
     *
     * @param campaignId ID of the campaign to update.
     * @param _isPaused  True to pause, false to unpause.
     */
    function setPause(uint256 campaignId, bool _isPaused) external onlyOwner campaignExists(campaignId) {
        campaigns[campaignId].isPaused = _isPaused;
        emit CampaignPauseSet(campaignId, _isPaused);
    }

    // ──────────────────────────────────────────────────────────────────
    // Operator — incentive grants
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Grant the campaign incentive to a recipient.
     *
     * Behaviour depends on the current time relative to the campaign window:
     *
     *   • Active window (start ≤ now < start + duration):
     *     The incentive amount is ASSIGNED to the recipient.  No tokens
     *     leave the funding wallet yet; the recipient must call release()
     *     after the window closes.
     *
     *   • After window (now ≥ start + duration):
     *     The incentive amount is TRANSFERRED directly from the funding
     *     wallet to the recipient.
     *
     * In both cases the campaign must not be paused and the recipient
     * must not have already received an incentive for this campaign.
     *
     * @param campaignId ID of the campaign.
     * @param recipient  Wallet that will receive the incentive.
     */
    function giveIncentive(uint256 campaignId, address recipient)
        external
        nonReentrant
        onlyOperator
        campaignExists(campaignId)
    {
        require(recipient != address(0), "TVDIncentive: invalid recipient");

        IncentiveCampaign storage c = campaigns[campaignId];

        require(!c.isPaused, "TVDIncentive: campaign is paused");
        require(
            block.timestamp >= c.start && block.timestamp < c.start + c.duration,
            "TVDIncentive: campaign grant window is not active"
        );
        require(!hasReceived[campaignId][recipient], "TVDIncentive: already received");
        require(c.maxWallets == 0 || c.walletsCount < c.maxWallets, "TVDIncentive: max wallets reached");

        // Update state before any external call (CEI).
        hasReceived[campaignId][recipient] = true;
        c.walletsCount += 1;

        uint256 amount = c.incentiveAmountPerWallet;

        if (block.timestamp < blockStartTime + blockDuration) {
            // ── Block period active: assign without transferring ──────
            campaignBalance[campaignId][recipient] += amount;
            emit IncentiveAssigned(campaignId, recipient, amount);
        } else {
            // ── Block period ended: transfer immediately ──────────────
            token.safeTransfer(recipient, amount);
            emit IncentiveTransferred(campaignId, recipient, amount);
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Recipient — release
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Claim assigned incentive tokens after block windows has ended.
     *
     * @dev    Tokens are pulled from the funding wallet via transferFrom,
     *         so the funding wallet must still hold sufficient balance and
     *         allowance at claim time.
     *
     * @param campaignId ID of the campaign to claim from.
     */
    function release(uint256 campaignId) external nonReentrant campaignExists(campaignId) {
        require(block.timestamp >= blockStartTime + blockDuration, "TVDIncentive: tokens are still locked");

        uint256 amount = campaignBalance[campaignId][msg.sender] + refundedHolding[msg.sender];
        require(amount > 0, "TVDIncentive: nothing to claim");

        // CEI: clear balance before external call.
        campaignBalance[campaignId][msg.sender] = 0;
        refundedHolding[msg.sender] = 0;

        token.safeTransfer(msg.sender, amount);

        emit IncentiveClaimed(campaignId, msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // IVestingProvider — implementation
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Total TVD assigned to `institution` across all campaigns.
     *         Does not include refundedHolding tokens held in the contract.
     */
    function assignedBalance(address institution) external view returns (uint256 total) {
        for (uint256 i = 0; i < campaignCount; i++) {
            total += campaignBalance[i][institution];
        }
    }

    /**
     * @notice Transfer `amount` of the institution's campaign-assigned TVD
     *         to the TVDElectoralCredits contract (caller).
     *         Deducts from campaigns in ascending order, pulling from each
     *         campaign's fundingWallet via transferFrom.
     *
     * @dev    Each fundingWallet must have pre-approved this contract.
     */
    function withdrawFor(address institution, uint256 amount) external nonReentrant onlyCreditsContract {
        uint256 remaining = amount;
        // Iterate from the last campaign backwards; a wallet is expected to
        // appear in only one campaign so the match is found on the first hit.
        for (uint256 i = campaignCount; i > 0 && remaining > 0; i--) {
            uint256 idx = i - 1;
            uint256 bal = campaignBalance[idx][institution];
            if (bal == 0) continue;

            uint256 toTake = bal >= remaining ? remaining : bal;
            campaignBalance[idx][institution] -= toTake;
            remaining -= toTake;

            token.safeTransfer(msg.sender, toTake);
        }
        require(remaining == 0, "TVDIncentive: insufficient assigned balance");
        emit InstitutionTokensWithdrawn(institution, amount);
    }

    /**
     * @notice Record tokens returned from TVDElectoralCredits after liquidation.
     *         The caller must have already transferred the tokens to this contract.
     *
     * @param institution The institution whose balance to restore.
     * @param amount      Amount of TVD (wei) credited back.
     */
    function creditRefund(address institution, uint256 amount) external onlyCreditsContract {
        require(institution != address(0), "TVDIncentive: invalid institution");
        refundedHolding[institution] += amount;
        emit InstitutionTokensRefunded(institution, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Unix timestamp after which assigned tokens may be released.
     *         Determined by the contract-level block period, not per campaign.
     */
    function unlockTime() external view returns (uint256) {
        return blockStartTime + blockDuration;
    }

    /**
     * @notice Unix timestamp when the grant window of a campaign closes.
     * @param campaignId ID of the campaign.
     */
    function campaignEndTime(uint256 campaignId) external view campaignExists(campaignId) returns (uint256) {
        return campaigns[campaignId].start + campaigns[campaignId].duration;
    }

    /**
     * @notice True if the campaign's grant window is currently open.
     * @param campaignId ID of the campaign.
     */
    function isActive(uint256 campaignId) external view campaignExists(campaignId) returns (bool) {
        IncentiveCampaign storage c = campaigns[campaignId];
        return block.timestamp >= c.start && block.timestamp < c.start + c.duration;
    }

    /**
     * @notice Get the amount of TVD tokens received by the caller for a specific campaign.
     * @param campaignId ID of the campaign.
     */
    function getAmountReceived(uint256 campaignId) external view returns (uint256) {
        return campaignBalance[campaignId][msg.sender];
    }
}
