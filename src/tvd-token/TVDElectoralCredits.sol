// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal interface that adds burn() to the standard ERC-20 surface.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title  TVDElectoralCredits
 * @notice SaaS Pay-As-You-Go electoral credit system for "Tu Voto Decide".
 *
 * ── Economic flow ────────────────────────────────────────────────────
 *
 *  1. TOP-UP (institution)
 *     An authorised operator calls topUp(institution, electionId, creditsToBuy).
 *     The contract pulls `creditsToBuy * tvdPerCredit` TVD from the
 *     institution's wallet (requires prior ERC-20 approval) and locks
 *     it inside this contract.  The institution's credit balance for
 *     that electionId increases by `creditsToBuy`.
 *
 *  2. ELECTION
 *     Each valid vote emitted triggers consumeVote(), called by an
 *     authorised operator (platform backend / relayer).
 *     One credit is deducted and the backing TVD is moved into a
 *     per-institution, per-election pending balance.  No tokens leave
 *     the contract yet.
 *
 *       TVD per vote = lockedTVD[electionId] / creditBalance[electionId]
 *
 *  3. LIQUIDATION
 *     After an election ends the operator calls liquidate(electionId).
 *     The pending TVD is settled:
 *
 *       burnBps / 10,000      → burned permanently (deflationary)
 *       remainder             → platformWallet
 *
 *     Any TVD backing unused credits is refunded to the institution.
 *
 *  4. ROLLOVER
 *     Credits not liquidated remain on the institution's account for that
 *     electionId and can be used in future votes within the same election
 *     (no expiry).
 *
 * ── Security notes ───────────────────────────────────────────────────
 *  • ReentrancyGuard on all state-changing functions with external calls.
 *  • Integer-division dust (< 1 wei per credit) accumulates in the
 *    contract and is recoverable by the admin via recoverDust().
 *  • tvdPerCredit changes only affect future top-ups; existing locked
 *    TVD is always distributed based on actual locked amounts.
 */
contract TVDElectoralCredits is AccessControl, ReentrancyGuard {
    using SafeERC20 for IBurnableERC20;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract.
    IBurnableERC20 public immutable token;

    /// @notice Wallet that receives TVD at liquidation. Adjustable by admin.
    address public platformWallet;

    /// @notice TVD (in wei) locked per electoral credit at top-up time.
    ///         Adjustable by admin; only affects future purchases.
    uint256 public tvdPerCredit;

    /// @notice Burn share applied at liquidation, in basis points (default 1000 = 10%).
    ///         Must be < 10,000; remainder goes to platformWallet.
    uint16 public burnBps;

    /// @notice Maximum TVD (in wei) that a single topUp() call may lock.
    ///         Adjustable by admin.
    uint256 public maxTokenPerElection;

    /// @notice Per-election state.
    struct Election {
        /// @dev Address of the institution that owns this election. Set on the
        ///      first topUp() and immutable thereafter (subsequent top-ups must
        ///      come from the same institution).
        address institution;
        uint256 creditBalance;
        uint256 lockedTVD;
        uint256 pendingTVD;
        /// @dev Credit balance snapshot taken right after the most recent topUp().
        uint256 startCreditBalance;
        /// @dev Locked TVD snapshot taken right after the most recent topUp().
        uint256 startLockedTVD;
        /// @dev True once liquidate() has settled this election;
        bool liquidated;
        /// @dev TVD burned by the most recent liquidate() call.
        uint256 burnedTVD;
        /// @dev TVD sent to platformWallet by the most recent liquidate() call.
        uint256 consumedTVD;
        /// @dev TVD refunded (to institution or vesting source) by the most recent liquidate() call.
        uint256 refundedTVD;
    }

    /// @notice State for each election, keyed by electionId.
    mapping(uint256 => Election) private elections;

    /// @notice Role authorised to call topUp / consumeVote / liquidate (platform operators / relayers).
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event TopUp(address indexed institution, uint256 electionId, uint256 creditsPurchased, uint256 tvdLocked);
    event VoteConsumed(address indexed institution, uint256 electionId, uint256 tvdAccrued);
    event Liquidated(
        address indexed institution, uint256 electionId, uint256 tvdToPlatform, uint256 tvdBurned, uint256 tvdRefunded
    );
    event OperatorUpdated(address indexed operator, bool authorized);
    event TvdPerCreditUpdated(uint256 oldRate, uint256 newRate);
    event BurnBpsUpdated(uint16 oldBurnBps, uint16 newBurnBps);
    event MaxTokenPerElectionUpdated(uint256 oldMax, uint256 newMax);
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event DustRecovered(uint256 amount);
    event VestingProviderAdded(address indexed provider);
    event VestingProviderRemoved(address indexed provider);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(
            hasRole(OPERATOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "TVDCredits: caller is not an authorized operator"
        );
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token          TVDToken address.
     * @param _admin          Address granted DEFAULT_ADMIN_ROLE (governance / multisig admin).
     * @param _tvdPerCredit   Initial TVD (wei) required per credit, e.g. 1e18 = 1 TVD.
     * @param _platformWallet Wallet that receives TVD for every consumed vote.
     */
    constructor(address _token, address _admin, uint256 _tvdPerCredit, address _platformWallet) {
        require(_token != address(0), "TVDCredits: invalid token");
        require(_admin != address(0), "TVDCredits: invalid admin");
        require(_tvdPerCredit > 0, "TVDCredits: rate must be > 0");
        require(_platformWallet != address(0), "TVDCredits: invalid platform wallet");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        token = IBurnableERC20(_token);
        tvdPerCredit = _tvdPerCredit;
        platformWallet = _platformWallet;
        burnBps = 1_000; // 10% default
        maxTokenPerElection = 100_000e18; // 100,000 TVD default
    }

    // ──────────────────────────────────────────────────────────────────
    // Institution — top-up
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Purchase electoral credits by locking TVD in this contract.
     *
     * @dev The institution must first call
     *      `TVDToken.approve(address(this), creditsToBuy * tvdPerCredit)`.
     *
     * @param institution   Address of the institution purchasing credits.
     * @param electionId    Identifier of the election these credits back.
     * @param creditsToBuy Number of electoral credits to purchase.
     */
    function topUp(address institution, uint256 electionId, uint256 creditsToBuy) external nonReentrant onlyOperator {
        require(institution != address(0), "TVDCredits: invalid institution");
        require(creditsToBuy > 0, "TVDCredits: credits must be > 0");

        uint256 tvdRequired = creditsToBuy * tvdPerCredit;
        // Overflow guard (redundant in Solidity ≥0.8 but explicit for clarity)
        require(tvdRequired / creditsToBuy == tvdPerCredit, "TVDCredits: arithmetic overflow");
        require(tvdRequired <= maxTokenPerElection, "TVDCredits: exceeds max token per election");

        Election storage inst = elections[electionId];

        if (inst.institution == address(0)) {
            inst.institution = institution;
        } else {
            require(inst.institution == institution, "TVDCredits: institution mismatch");
        }

        token.safeTransferFrom(institution, address(this), tvdRequired);
        inst.creditBalance += creditsToBuy;
        inst.lockedTVD += tvdRequired;
        inst.startCreditBalance = inst.creditBalance;
        inst.startLockedTVD = inst.lockedTVD;
        inst.liquidated = false;

        emit TopUp(institution, electionId, creditsToBuy, tvdRequired);
    }

    // ──────────────────────────────────────────────────────────────────
    // Operator — vote consumption
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Record one validated vote for an institution.
     *         Called by an authorised operator (platform relayer / backend).
     *
     * Deducts one credit and moves the backing TVD into `pendingTVD`.
     * No tokens leave the contract here; settlement happens in liquidate().
     *
     * @param electionId  Identifier of the election the vote belongs to.
     */
    function consumeVote(uint256 electionId) external nonReentrant onlyOperator {
        Election storage election = elections[electionId];
        address institution = election.institution;
        require(institution != address(0), "TVDCredits: invalid institution");
        require(election.creditBalance > 0, "TVDCredits: election has no credits");

        // TVD earmarked for this vote (weighted-average rate).
        // Any rounding dust (< 1 wei) stays in lockedTVD until liquidation.
        uint256 tvdForVote = election.lockedTVD / election.creditBalance;

        election.creditBalance -= 1;
        election.lockedTVD -= tvdForVote;
        election.pendingTVD += tvdForVote;

        emit VoteConsumed(institution, electionId, tvdForVote);
    }

    /**
     * @notice Settle a completed election for the given institution.
     *
     * Distributes `pendingTVD[institution]` (accrued from consumed votes):
     *   • burnBps / 10,000  → burned permanently
     *   • remainder         → platformWallet
     *
     * Then refunds any TVD backing unused credits back to the institution
     * and resets all institution state to zero.
     *
     * @param electionId  Identifier of the election being liquidated.
     */
    function liquidate(uint256 electionId) external nonReentrant onlyOperator {
        Election storage inst = elections[electionId];
        address institution = inst.institution;
        require(institution != address(0), "TVDCredits: invalid institution");

        uint256 pending = inst.pendingTVD;
        uint256 refund = inst.lockedTVD;

        require(pending > 0 || refund > 0, "TVDCredits: nothing to liquidate");

        // Reset all institution state before external calls (CEI pattern).
        inst.pendingTVD = 0;
        inst.lockedTVD = 0;
        inst.creditBalance = 0;
        inst.liquidated = true;

        // Distribute consumed TVD.
        uint256 toBurn = (pending * burnBps) / 10_000;
        uint256 toPlatform = pending - toBurn;

        inst.burnedTVD = toBurn;
        inst.consumedTVD = toPlatform;
        inst.refundedTVD = refund;

        if (toPlatform > 0) token.safeTransfer(platformWallet, toPlatform);
        if (toBurn > 0) token.burn(toBurn);

        // Refund unused credit TVD.
        if (refund > 0) {
            token.safeTransfer(institution, refund);
        }

        emit Liquidated(institution, electionId, toPlatform, toBurn, refund);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — configuration
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Authorise or deauthorise an operator.
     * @param operator   Address to update.
     * @param authorized True to grant, false to revoke.
     */
    function setOperator(address operator, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(operator != address(0), "TVDCredits: invalid operator");
        if (authorized) {
            _grantRole(OPERATOR_ROLE, operator);
        } else {
            _revokeRole(OPERATOR_ROLE, operator);
        }
        emit OperatorUpdated(operator, authorized);
    }

    /**
     * @notice Update the burn share applied at liquidation.
     * @param _burnBps Basis points to burn (e.g. 1000 = 10%). Must be < 10,000.
     */
    function setBurnBps(uint16 _burnBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_burnBps < 10_000, "TVDCredits: burnBps must be < 10000");
        emit BurnBpsUpdated(burnBps, _burnBps);
        burnBps = _burnBps;
    }

    /**
     * @notice Update the TVD-per-credit exchange rate.
     *         Only affects future topUp() calls; existing locked TVD is unaffected.
     *
     * @param newRate New TVD (wei) per credit.
     */
    function setTvdPerCredit(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRate > 0, "TVDCredits: rate must be > 0");
        emit TvdPerCreditUpdated(tvdPerCredit, newRate);
        tvdPerCredit = newRate;
    }

    /**
     * @notice Update the maximum TVD (wei) that a single topUp() call may lock.
     * @param newMax New maximum TVD (wei) per topUp() call.
     */
    function setMaxTokenPerElection(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxTokenPerElectionUpdated(maxTokenPerElection, newMax);
        maxTokenPerElection = newMax;
    }

    /**
     * @notice Update the wallet that receives TVD at liquidation.
     * @param newPlatformWallet New platform wallet address.
     */
    function setPlatformWallet(address newPlatformWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPlatformWallet != address(0), "TVDCredits: invalid platform wallet");
        emit PlatformWalletUpdated(platformWallet, newPlatformWallet);
        platformWallet = newPlatformWallet;
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice get election state
     *
     * @param electionId  Identifier of the election.
     */
    function getElection(uint256 electionId)
        external
        view
        returns (
            address institution,
            uint256 creditBalance,
            uint256 lockedTVD,
            uint256 pendingTVD,
            uint256 startCreditBalance,
            uint256 startLockedTVD,
            bool liquidated,
            uint256 burnedTVD,
            uint256 consumedTVD,
            uint256 refundedTVD
        )
    {
        Election storage inst = elections[electionId];
        institution = inst.institution;
        creditBalance = inst.creditBalance;
        lockedTVD = inst.lockedTVD;
        pendingTVD = inst.pendingTVD;
        startCreditBalance = inst.startCreditBalance;
        startLockedTVD = inst.startLockedTVD;
        liquidated = inst.liquidated;
        burnedTVD = inst.burnedTVD;
        consumedTVD = inst.consumedTVD;
        refundedTVD = inst.refundedTVD;
    }
}
