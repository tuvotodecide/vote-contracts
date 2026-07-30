// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TVDToken} from "./TVDToken.sol";

/**
 * @title  TVDIncentiveCampaigns
 * @notice Operator-driven TVD incentive distribution with a time-locked
 *         grant window. Only one campaign can be active at a time.
 *
 * ── Lifecycle ────────────────────────────────────────────────────────
 *
 *  1. CREATE  (admin)
 *     Admin calls createCampaign() to configure the single campaign slot,
 *     specifying the per-wallet TVD amount, active window, cap, and the
 *     funding wallet. The funding wallet must pre-approve this contract
 *     for the full budget. A new campaign can only be created once the
 *     previous one's unused tokens have been refunded via refundCampaign()
 *     — regardless of whether its window has elapsed.
 *
 *  2. GIVE INCENTIVE  (operator)
 *     During the active window (start ≤ now < start + duration), tokens
 *     are transferred directly to the recipient from this contract's
 *     balance. The campaign must not be paused or already refunded. A
 *     wallet may only ever receive the incentive once, across all
 *     campaigns.
 *
 *  3. PAUSE / UNPAUSE  (admin)
 *     Admin may pause the campaign at any time to halt new incentive
 *     grants without affecting the campaign configuration.
 *
 *  4. REFUND  (admin)
 *     Admin may refund the campaign at any time — including after its
 *     grant window has already passed — blocking further grants and
 *     sweeping the remaining (unspent) token balance back to the
 *     funding wallet. This must happen before a new campaign can be
 *     created.
 *
 * ── Security notes ───────────────────────────────────────────────────
 *  • Only one grant per wallet, ever (hasReceived guard).
 *  • CEI pattern: state is updated before external token calls.
 *  • The funding wallet bears responsibility for maintaining sufficient
 *    allowance and balance for the lifetime of the campaign.
 */
contract TVDIncentiveCampaigns is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────

    /// @notice Default campaign duration when none is specified at creation.
    uint256 public constant DEFAULT_DURATION = 365 days;

    /// @notice Role authorised to call giveIncentive().
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract used for all transfers.
    TVDToken public immutable token;

    /// @notice TVD amount (wei) distributed to each eligible wallet.
    uint256 public incentiveAmountPerWallet;
    /// @notice Unix timestamp when the campaign becomes active.
    uint256 public start;
    /// @notice Active-window duration in seconds (default: DEFAULT_DURATION = 365 days).
    uint256 public duration;
    /// @notice When true, giveIncentive() is blocked for the current campaign.
    bool public isPaused;
    /// @notice Maximum number of wallets that may receive the incentive. Must be > 0.
    uint256 public maxWallets;
    /// @notice Source wallet for all token transfers.
    ///         IMPORTANT: this wallet must call token.approve(address(this), budget)
    ///         before createCampaign() can pull the budget.
    address public fundingWallet;
    /// @notice Running count of wallets that have already received the incentive.
    uint256 public walletsCount;
    /// @notice True once the current campaign's unused tokens have been
    ///         refunded to the funding wallet. Starts true (no campaign to
    ///         refund yet) and must be true again before a new campaign can
    ///         be created.
    bool public isCampaignRefunded;

    /// @notice Wallets that have already received an incentive. A wallet may
    ///         only ever be granted the incentive once, across all campaigns.
    mapping(address => bool) public hasReceived;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event CampaignCreated(
        uint256 incentiveAmountPerWallet,
        uint256 start,
        uint256 duration,
        uint256 maxWallets,
        address indexed fundingWallet
    );
    event IncentiveTransferred(address indexed recipient, uint256 amount);
    event CampaignPauseSet(bool isPaused);
    event CampaignRefunded(address indexed fundingWallet, uint256 refundedAmount);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier campaignActive() {
        require(fundingWallet != address(0), "TVDIncentive: no active campaign");
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token    TVDToken address.
     * @param _admin    Address granted DEFAULT_ADMIN_ROLE (governance).
     * @param _operator Address granted OPERATOR_ROLE (giveIncentive()).
     */
    constructor(address _token, address _admin, address _operator) {
        require(_token != address(0), "TVDIncentive: invalid token");
        require(_admin != address(0), "TVDIncentive: invalid admin");
        require(_operator != address(0), "TVDIncentive: invalid operator");

        token = TVDToken(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);

        // No campaign exists yet, so there is nothing to refund.
        isCampaignRefunded = true;
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — campaign lifecycle
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Configure and fund the single campaign slot.
     *
     * @dev    Pass 0 for `_duration` to use the DEFAULT_DURATION (365 days).
     *         The fundingWallet must approve this contract for at least
     *         incentiveAmountPerWallet * maxWallets TVD before any grants
     *         can be processed. Can only be called once the previous
     *         campaign's unused tokens have been refunded via
     *         refundCampaign(), regardless of whether its window elapsed.
     *
     * @param _incentiveAmountPerWallet TVD (wei) each eligible wallet receives.
     * @param _start                    Unix timestamp when the campaign becomes active.
     * @param _duration                 Active-window length in seconds (0 → 365 days).
     * @param _maxWallets               Cap on eligible wallets. Must be > 0.
     * @param _fundingWallet            Wallet that provides the tokens.
     *                                  Must pre-approve this contract via token.approve().
     */
    function createCampaign(
        uint256 _incentiveAmountPerWallet,
        uint256 _start,
        uint256 _duration,
        uint256 _maxWallets,
        address _fundingWallet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_incentiveAmountPerWallet > 0, "TVDIncentive: incentive must be > 0");
        require(_start > 0, "TVDIncentive: invalid start time");
        require(_fundingWallet != address(0), "TVDIncentive: invalid funding wallet");
        require(_maxWallets > 0, "TVDIncentive: max wallets must be > 0");
        require(isCampaignRefunded, "TVDIncentive: previous campaign not refunded");

        uint256 effectiveDuration = _duration == 0 ? DEFAULT_DURATION : _duration;

        incentiveAmountPerWallet = _incentiveAmountPerWallet;
        start = _start;
        duration = effectiveDuration;
        isPaused = false;
        maxWallets = _maxWallets;
        fundingWallet = _fundingWallet;
        walletsCount = 0;
        isCampaignRefunded = false;

        IERC20(address(token)).safeTransferFrom(_fundingWallet, address(this), _incentiveAmountPerWallet * _maxWallets);

        emit CampaignCreated(_incentiveAmountPerWallet, _start, effectiveDuration, _maxWallets, _fundingWallet);
    }

    /**
     * @notice Pause or unpause the current campaign.
     *         Pausing blocks new incentive grants but does not affect
     *         the campaign configuration.
     * @param _isPaused True to pause, false to unpause.
     */
    function setPause(bool _isPaused) external onlyRole(DEFAULT_ADMIN_ROLE) campaignActive {
        isPaused = _isPaused;
        emit CampaignPauseSet(_isPaused);
    }

    /**
     * @notice Refund the current campaign's unused tokens, blocking further
     *         grants and sweeping the remaining token balance back to the
     *         funding wallet. Callable at any time, including after the
     *         grant window has already passed. Must be called before a new
     *         campaign can be created.
     */
    function refundCampaign() external onlyRole(DEFAULT_ADMIN_ROLE) campaignActive {
        require(!isCampaignRefunded, "TVDIncentive: campaign already refunded");

        isCampaignRefunded = true;

        uint256 remaining = token.balanceOf(address(this));
        if (remaining > 0) {
            IERC20(address(token)).safeTransfer(fundingWallet, remaining);
        }

        emit CampaignRefunded(fundingWallet, remaining);
    }

    // ──────────────────────────────────────────────────────────────────
    // Operator — incentive grants
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Grant the campaign incentive to a recipient.
     *
     * During the active window (start ≤ now < start + duration) the
     * incentive amount is transferred directly from this contract's
     * balance to the recipient. The campaign must not be paused or
     * already refunded, and the recipient must not have already received
     * an incentive (ever, across all campaigns).
     *
     * @param recipient Wallet that will receive the incentive.
     */
    function giveIncentive(address recipient) external nonReentrant onlyRole(OPERATOR_ROLE) campaignActive {
        require(recipient != address(0), "TVDIncentive: invalid recipient");
        require(!isCampaignRefunded, "TVDIncentive: campaign has been refunded");
        require(!isPaused, "TVDIncentive: campaign is paused");
        require(
            block.timestamp >= start && block.timestamp < start + duration,
            "TVDIncentive: campaign grant window is not active"
        );
        require(!hasReceived[recipient], "TVDIncentive: already received");
        require(walletsCount < maxWallets, "TVDIncentive: max wallets reached");

        // Update state before any external call (CEI).
        hasReceived[recipient] = true;
        walletsCount += 1;

        uint256 amount = incentiveAmountPerWallet;

        IERC20(address(token)).safeTransfer(recipient, amount);
        token.setApplyLockup(recipient, true);
        emit IncentiveTransferred(recipient, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Unix timestamp when the current campaign's grant window closes.
     */
    function campaignEndTime() external view campaignActive returns (uint256) {
        return start + duration;
    }

    /**
     * @notice True if the current campaign's grant window is open and it
     *         hasn't been refunded.
     */
    function isActive() external view returns (bool) {
        return !isCampaignRefunded && block.timestamp >= start && block.timestamp < start + duration;
    }
}
