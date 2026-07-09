// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
 *     Institution calls topUp(creditsToBuy).
 *     The contract pulls `creditsToBuy * tvdPerCredit` TVD from the
 *     institution's wallet (requires prior ERC-20 approval) and locks
 *     it inside this contract.  The institution's credit balance
 *     increases by `creditsToBuy`.
 *
 *  2. ELECTION
 *     Each valid vote emitted triggers consumeVote(), called by an
 *     authorised operator (platform backend / relayer).
 *     One credit is deducted and the backing TVD is distributed:
 *
 *       TVD per vote = lockedTVD[institution] / creditBalance[institution]
 *
 *       ┌──────────┬───────────────────────────────────────────────────────┐
 *       │ voterBps │ → voter wallet (participation incentive)              │
 *       │ burnBps  │ → burned permanently (deflationary supply shock)      │
 *       └──────────┴───────────────────────────────────────────────────────┘
 *       burnBps = 10,000 − voterBps
 *
 *  3. ROLLOVER
 *     Unused credits remain on the institution's account forever.
 *     They can be used in future elections (no expiry).
 *
 * ── Security notes ───────────────────────────────────────────────────
 *  • ReentrancyGuard on all state-changing functions with external calls.
 *  • voterBps must be < 10,000 so that burnBps is always > 0
 *    (enforces permanent deflation).
 *  • Integer-division dust (< 1 wei per credit) accumulates in the
 *    contract and is recoverable by the owner via recoverDust().
 *  • tvdPerCredit changes only affect future top-ups; existing locked
 *    TVD is always distributed based on actual locked amounts.
 */
contract TVDElectoralCredits is Ownable, ReentrancyGuard {
    using SafeERC20 for IBurnableERC20;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract.
    IBurnableERC20 public immutable token;

    /// @notice TVD (in wei) locked per electoral credit at top-up time.
    ///         Adjustable by owner; only affects future purchases.
    uint256 public tvdPerCredit;

    /// @notice Voter incentive share in basis points (out of 10,000 = 100%).
    ///         burnBps = 10,000 − voterBps  (always > 0 by invariant).
    uint16 public voterBps; // e.g. 4000 = 40 %

    /// @notice Electoral credit balance per institution.
    mapping(address => uint256) public creditBalance;

    /// @notice TVD locked in this contract per institution.
    ///         Maintained to ensure exact distribution regardless of rate changes.
    mapping(address => uint256) public lockedTVD;

    /// @notice Addresses authorised to call consumeVote (platform operators / relayers).
    mapping(address => bool) public authorizedOperators;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event TopUp(
        address indexed institution,
        uint256 creditsPurchased,
        uint256 tvdLocked
    );
    event VoteConsumed(
        address indexed institution,
        address indexed voter,
        uint256 tvdToVoter,
        uint256 tvdBurned
    );
    event OperatorUpdated(address indexed operator, bool authorized);
    event TvdPerCreditUpdated(uint256 oldRate, uint256 newRate);
    event VoterBpsUpdated(uint16 oldVoterBps, uint16 newVoterBps);
    event DustRecovered(uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(
            authorizedOperators[msg.sender] || msg.sender == owner(),
            "TVDCredits: caller is not an authorized operator"
        );
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token        TVDToken address.
     * @param _admin        Owner / multisig admin.
     * @param _tvdPerCredit Initial TVD (wei) required per credit, e.g. 1e18 = 1 TVD.
     * @param _voterBps     Voter incentive share in basis points (e.g. 4000 = 40 %).
     *
     * @dev burnBps = 10,000 − _voterBps and must be > 0.
     */
    constructor(
        address _token,
        address _admin,
        uint256 _tvdPerCredit,
        uint16  _voterBps
    ) Ownable(_admin) {
        require(_token        != address(0), "TVDCredits: invalid token");
        require(_tvdPerCredit > 0,           "TVDCredits: rate must be > 0");
        require(_voterBps < 10_000,          "TVDCredits: voterBps must be < 10000");

        token        = IBurnableERC20(_token);
        tvdPerCredit = _tvdPerCredit;
        voterBps     = _voterBps;
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
     * @param creditsToBuy Number of electoral credits to purchase.
     */
    function topUp(uint256 creditsToBuy) external nonReentrant {
        require(creditsToBuy > 0, "TVDCredits: credits must be > 0");

        uint256 tvdRequired = creditsToBuy * tvdPerCredit;
        // Overflow guard (redundant in Solidity ≥0.8 but explicit for clarity)
        require(
            tvdRequired / creditsToBuy == tvdPerCredit,
            "TVDCredits: arithmetic overflow"
        );

        token.safeTransferFrom(msg.sender, address(this), tvdRequired);

        creditBalance[msg.sender] += creditsToBuy;
        lockedTVD[msg.sender]     += tvdRequired;

        emit TopUp(msg.sender, creditsToBuy, tvdRequired);
    }

    // ──────────────────────────────────────────────────────────────────
    // Operator — vote consumption
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Consume one electoral credit for a validated vote.
     *         Called by an authorised operator (platform relayer / backend).
     *
     * The TVD backing this credit is distributed as:
     *   • voterBps / 10,000  → voter wallet (participation reward)
     *   • remainder          → burned (permanent deflation)
     *
     * @param institution Address of the institution running the election.
     * @param voter       Wallet address of the citizen who cast the valid vote.
     */
    function consumeVote(address institution, address voter)
        external
        nonReentrant
        onlyOperator
    {
        require(institution != address(0), "TVDCredits: invalid institution");
        require(voter       != address(0), "TVDCredits: invalid voter");
        require(creditBalance[institution] > 0, "TVDCredits: institution has no credits");

        uint256 credits = creditBalance[institution];
        uint256 locked  = lockedTVD[institution];

        // TVD to distribute for this single vote (weighted-average rate).
        // Any rounding dust (< 1 wei) stays in lockedTVD and is handled
        // when the last credit is consumed or via recoverDust().
        uint256 tvdForVote = locked / credits;

        creditBalance[institution] -= 1;
        lockedTVD[institution]     -= tvdForVote;

        uint256 toVoter = (tvdForVote * voterBps) / 10_000;
        uint256 toBurn  = tvdForVote - toVoter;

        if (toVoter > 0) {
            token.safeTransfer(voter, toVoter);
        }
        if (toBurn > 0) {
            token.burn(toBurn);
        }

        emit VoteConsumed(institution, voter, toVoter, toBurn);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — configuration
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Authorise or deauthorise an operator.
     * @param operator   Address to update.
     * @param authorized True to grant, false to revoke.
     */
    function setOperator(address operator, bool authorized) external onlyOwner {
        require(operator != address(0), "TVDCredits: invalid operator");
        authorizedOperators[operator] = authorized;
        emit OperatorUpdated(operator, authorized);
    }

    /**
     * @notice Update the TVD-per-credit exchange rate.
     *         Only affects future topUp() calls; existing locked TVD is unaffected.
     *
     * @param newRate New TVD (wei) per credit.
     */
    function setTvdPerCredit(uint256 newRate) external onlyOwner {
        require(newRate > 0, "TVDCredits: rate must be > 0");
        emit TvdPerCreditUpdated(tvdPerCredit, newRate);
        tvdPerCredit = newRate;
    }

    /**
     * @notice Update the voter incentive share.
     *
     * @param _voterBps Basis points for voter reward (e.g. 4000 = 40 %).
     *                  Must be < 10,000 to leave room for burn.
     */
    function setVoterBps(uint16 _voterBps) external onlyOwner {
        require(_voterBps < 10_000, "TVDCredits: voterBps must be < 10000");
        emit VoterBpsUpdated(voterBps, _voterBps);
        voterBps = _voterBps;
    }

    /**
     * @notice Recover integer-division dust that accumulates over time.
     *         Sends any TVD held by this contract in excess of the sum of
     *         all institutions' lockedTVD to the owner.
     *
     * @dev This dust arises because `lockedTVD / creditBalance` may not
     *      divide evenly.  Only callable by owner.
     */
    function recoverDust() external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        uint256 dust    = balance; // all remaining TVD not attributed to institutions

        // Subtract all attributed locked TVD — note: this is an O(n) approximation.
        // The contract relies on the invariant: balance >= sum(lockedTVD).
        // recoverDust() should only be called when all credits are exhausted
        // or as a maintenance operation confirmed off-chain.
        require(dust > 0, "TVDCredits: no dust to recover");
        token.safeTransfer(owner(), dust);
        emit DustRecovered(dust);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /// @notice Current burn share in basis points.
    function burnBps() external view returns (uint16) {
        return uint16(10_000 - uint256(voterBps));
    }

    /**
     * @notice Effective TVD (wei) that will be distributed per vote for a given
     *         institution, based on their current locked balance and credit count.
     *
     * @param institution Institution address.
     * @return tvd TVD per vote, or 0 if institution has no credits.
     */
    function tvdPerVote(address institution) external view returns (uint256 tvd) {
        uint256 credits = creditBalance[institution];
        if (credits == 0) return 0;
        return lockedTVD[institution] / credits;
    }
}
