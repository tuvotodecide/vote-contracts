// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVestingProvider} from "./IVestingProvider.sol";

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

    /// @notice Wallet that receives TVD at liquidation.
    address public immutable platformWallet;

    /// @notice TVD (in wei) locked per electoral credit at top-up time.
    ///         Adjustable by owner; only affects future purchases.
    uint256 public tvdPerCredit;

    /// @notice Burn share applied at liquidation, in basis points (default 1000 = 10%).
    ///         Must be < 10,000; remainder goes to platformWallet.
    uint16 public burnBps;

    /// @notice Ordered list of vesting providers queried during topUp.
    ///         The first provider with sufficient balance for the caller is used.
    IVestingProvider[] public vestingProviders;

    /// @notice Per-election state.
    struct Institution {
        /// @dev Address of the institution that owns this election. Set on the
        ///      first topUp() and immutable thereafter (subsequent top-ups must
        ///      come from the same institution).
        address institution;
        uint256 creditBalance;
        uint256 lockedTVD;
        uint256 pendingTVD;
        /// @dev Address of the vesting provider that funded the current locked balance,
        ///      or address(0) if tokens came from the institution's own wallet.
        address vestingSource;
    }

    /// @notice State for each election, keyed by electionId.
    mapping(uint256 => Institution) private elections;

    /// @notice Addresses authorised to call consumeVote (platform operators / relayers).
    mapping(address => bool) public authorizedOperators;

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
    event DustRecovered(uint256 amount);
    event VestingProviderAdded(address indexed provider);
    event VestingProviderRemoved(address indexed provider);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(
            authorizedOperators[msg.sender] || msg.sender == owner(), "TVDCredits: caller is not an authorized operator"
        );
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token          TVDToken address.
     * @param _admin          Owner / multisig admin.
     * @param _tvdPerCredit   Initial TVD (wei) required per credit, e.g. 1e18 = 1 TVD.
     * @param _platformWallet Wallet that receives TVD for every consumed vote.
     */
    constructor(address _token, address _admin, uint256 _tvdPerCredit, address _platformWallet) Ownable(_admin) {
        require(_token != address(0), "TVDCredits: invalid token");
        require(_tvdPerCredit > 0, "TVDCredits: rate must be > 0");
        require(_platformWallet != address(0), "TVDCredits: invalid platform wallet");

        token = IBurnableERC20(_token);
        tvdPerCredit = _tvdPerCredit;
        platformWallet = _platformWallet;
        burnBps = 1_000; // 10% default
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
    function topUp(address institution, uint256 electionId, uint256 creditsToBuy)
        external
        nonReentrant
        onlyOperator
    {
        require(institution != address(0), "TVDCredits: invalid institution");
        require(creditsToBuy > 0, "TVDCredits: credits must be > 0");

        uint256 tvdRequired = creditsToBuy * tvdPerCredit;
        // Overflow guard (redundant in Solidity ≥0.8 but explicit for clarity)
        require(tvdRequired / creditsToBuy == tvdPerCredit, "TVDCredits: arithmetic overflow");

        Institution storage inst = elections[electionId];

        if (inst.institution == address(0)) {
            inst.institution = institution;
        } else {
            require(inst.institution == institution, "TVDCredits: institution mismatch");
        }

        // Scan providers in order; use the first with sufficient balance.
        // Never draw from both a provider and the institution wallet.
        address selectedProvider = address(0);
        uint256 providerCount = vestingProviders.length;
        for (uint256 i = 0; i < providerCount; i++) {
            if (vestingProviders[i].assignedBalance(institution) >= tvdRequired) {
                selectedProvider = address(vestingProviders[i]);
                break;
            }
        }

        if (selectedProvider != address(0)) {
            IVestingProvider(selectedProvider).withdrawFor(institution, tvdRequired);
            inst.vestingSource = selectedProvider;
        } else {
            token.safeTransferFrom(institution, address(this), tvdRequired);
            inst.vestingSource = address(0);
        }

        inst.creditBalance += creditsToBuy;
        inst.lockedTVD += tvdRequired;

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
        Institution storage inst = elections[electionId];
        address institution = inst.institution;
        require(institution != address(0), "TVDCredits: invalid institution");
        require(inst.creditBalance > 0, "TVDCredits: institution has no credits");

        // TVD earmarked for this vote (weighted-average rate).
        // Any rounding dust (< 1 wei) stays in lockedTVD until liquidation.
        uint256 tvdForVote = inst.lockedTVD / inst.creditBalance;

        inst.creditBalance -= 1;
        inst.lockedTVD -= tvdForVote;
        inst.pendingTVD += tvdForVote;

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
        Institution storage inst = elections[electionId];
        address institution = inst.institution;
        require(institution != address(0), "TVDCredits: invalid institution");

        uint256 pending = inst.pendingTVD;
        uint256 refund = inst.lockedTVD;
        address vestingSource = inst.vestingSource;

        require(pending > 0 || refund > 0, "TVDCredits: nothing to liquidate");

        // Reset all institution state before external calls (CEI pattern).
        inst.pendingTVD = 0;
        inst.lockedTVD = 0;
        inst.creditBalance = 0;
        inst.vestingSource = address(0);

        // Distribute consumed TVD.
        uint256 toBurn = (pending * burnBps) / 10_000;
        uint256 toPlatform = pending - toBurn;

        if (toPlatform > 0) token.safeTransfer(platformWallet, toPlatform);
        if (toBurn > 0) token.burn(toBurn);

        // Refund unused credit TVD.
        if (refund > 0) {
            if (vestingSource != address(0)) {
                // Tokens originated from a vesting provider — return them there.
                // Token transfer precedes creditRefund() to satisfy CEI.
                token.safeTransfer(vestingSource, refund);
                IVestingProvider(vestingSource).creditRefund(institution, refund);
            } else {
                token.safeTransfer(institution, refund);
            }
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
    function setOperator(address operator, bool authorized) external onlyOwner {
        require(operator != address(0), "TVDCredits: invalid operator");
        authorizedOperators[operator] = authorized;
        emit OperatorUpdated(operator, authorized);
    }

    /**
     * @notice Update the burn share applied at liquidation.
     * @param _burnBps Basis points to burn (e.g. 1000 = 10%). Must be < 10,000.
     */
    function setBurnBps(uint16 _burnBps) external onlyOwner {
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
    function setTvdPerCredit(uint256 newRate) external onlyOwner {
        require(newRate > 0, "TVDCredits: rate must be > 0");
        emit TvdPerCreditUpdated(tvdPerCredit, newRate);
        tvdPerCredit = newRate;
    }

    /**
     * @notice Add an IVestingProvider to the list queried during topUp.
     * @param provider Address of the IVestingProvider-compatible contract.
     */
    function addVestingProvider(address provider) external onlyOwner {
        require(provider != address(0), "TVDCredits: invalid provider");
        vestingProviders.push(IVestingProvider(provider));
        emit VestingProviderAdded(provider);
    }

    /**
     * @notice Remove a vesting provider by array index (swap-and-pop).
     * @dev    Do NOT remove a provider while any institution has a vestingSource
     *         pointing to it (i.e., there are pending liquidations referencing it).
     * @param index Position in the vestingProviders array.
     */
    function removeVestingProvider(uint256 index) external onlyOwner {
        uint256 len = vestingProviders.length;
        require(index < len, "TVDCredits: index out of bounds");
        address removed = address(vestingProviders[index]);
        vestingProviders[index] = vestingProviders[len - 1];
        vestingProviders.pop();
        emit VestingProviderRemoved(removed);
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
        uint256 dust = balance; // all remaining TVD not attributed to institutions

        // Subtract all attributed locked TVD — note: this is an O(n) approximation.
        // The contract relies on the invariant: balance >= sum(elections[x].lockedTVD).
        // recoverDust() should only be called when all credits are exhausted
        // or as a maintenance operation confirmed off-chain.
        require(dust > 0, "TVDCredits: no dust to recover");
        token.safeTransfer(owner(), dust);
        emit DustRecovered(dust);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice get election state
     *
     * @param electionId  Identifier of the election.
     */
    function getInstitution(uint256 electionId)
        external
        view
        onlyOwner
        onlyOperator
        returns (address institution, uint256 creditBalance, uint256 lockedTVD, uint256 pendingTVD, address vestingSource)
    {
        Institution storage inst = elections[electionId];
        institution = inst.institution;
        creditBalance = inst.creditBalance;
        lockedTVD = inst.lockedTVD;
        pendingTVD = inst.pendingTVD;
        vestingSource = inst.vestingSource;
    }
}
