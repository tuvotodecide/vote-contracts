// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  TVDVesting
 * @notice Cliff + linear vesting contract for Team, Core members and Advisors.
 *
 * Default schedule per the $TVD tokenomics whitepaper:
 *   • Cliff   : 12 months (365 days) — zero tokens released.
 *   • Vesting : 24 months linear (730 days) — 131,250 TVD/month.
 *   • Total   :  3,150,000 TVD across all beneficiaries.
 *
 * The TVDToken constructor mints 3,150,000 TVD directly to this contract.
 * The owner (admin multisig) then calls addBeneficiary() for each recipient.
 *
 * Sub-allocations (from whitepaper):
 *   • Core Team (CEO/CTO/COO)  — 10 % of total supply  (2,100,000 TVD)
 *   • Talent Reserve           —  3 % of total supply  (  630,000 TVD)
 *   • Advisors                 —  2 % of total supply  (  420,000 TVD)
 */
contract TVDVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    IERC20 public immutable token;

    struct VestingSchedule {
        uint256 totalAmount;    // Total TVD allocated to this beneficiary
        uint256 releasedAmount; // TVD already transferred to beneficiary
        uint64  startTime;      // Unix timestamp of schedule creation (TGE)
        uint64  cliffDuration;  // Seconds during which nothing is released
        uint64  vestingDuration;// Seconds of linear release after the cliff ends
        bool    revoked;        // True if admin revoked unvested portion
    }

    mapping(address => VestingSchedule) public schedules;
    address[] private _beneficiaryList;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event BeneficiaryAdded(
        address indexed beneficiary,
        uint256 amount,
        uint64  cliffDuration,
        uint64  vestingDuration
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(address indexed beneficiary, uint256 unvestedRefunded);

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token TVDToken contract address.
     * @param _admin Owner / admin multisig (Ownable).
     */
    constructor(address _token, address _admin) Ownable(_admin) {
        require(_token != address(0), "TVDVesting: invalid token");
        token = IERC20(_token);
    }

    // ──────────────────────────────────────────────────────────────────
    // Owner — schedule management
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Register a new beneficiary with their vesting schedule.
     *         Starts the cliff countdown from the current block timestamp.
     *
     * @param beneficiary     Recipient address.
     * @param amount          Total TVD to vest (must fit within contract balance).
     * @param cliffDuration   Seconds of hard lock-up (e.g. 365 days).
     * @param vestingDuration Seconds of linear release after cliff (e.g. 730 days).
     */
    function addBeneficiary(
        address beneficiary,
        uint256 amount,
        uint64  cliffDuration,
        uint64  vestingDuration
    ) external onlyOwner {
        require(beneficiary     != address(0), "TVDVesting: invalid beneficiary");
        require(amount          > 0,           "TVDVesting: amount must be > 0");
        require(vestingDuration > 0,           "TVDVesting: vesting duration must be > 0");
        require(
            schedules[beneficiary].totalAmount == 0,
            "TVDVesting: beneficiary already registered"
        );
        require(
            token.balanceOf(address(this)) >= amount,
            "TVDVesting: insufficient contract balance"
        );

        schedules[beneficiary] = VestingSchedule({
            totalAmount:     amount,
            releasedAmount:  0,
            startTime:       uint64(block.timestamp),
            cliffDuration:   cliffDuration,
            vestingDuration: vestingDuration,
            revoked:         false
        });
        _beneficiaryList.push(beneficiary);

        emit BeneficiaryAdded(beneficiary, amount, cliffDuration, vestingDuration);
    }

    /**
     * @notice Revoke a beneficiary's unvested tokens (e.g. team member departure).
     *         Any already-vested-but-unreleased tokens are first sent to the beneficiary.
     *         The unvested portion is kept in the contract.
     *
     * @param beneficiary Address to revoke.
     */
    function revoke(address beneficiary) external onlyOwner nonReentrant {
        VestingSchedule storage s = schedules[beneficiary];
        require(s.totalAmount > 0,  "TVDVesting: beneficiary not found");
        require(!s.revoked,         "TVDVesting: schedule already revoked");

        uint256 vested    = _vestedAmount(s);
        uint256 toRelease = vested - s.releasedAmount;

        // Release what was already earned before the revoke
        if (toRelease > 0) {
            s.releasedAmount = vested;
            token.safeTransfer(beneficiary, toRelease);
            emit TokensReleased(beneficiary, toRelease);
        }

        uint256 unvested = s.totalAmount - vested;
        s.revoked = true;

        emit ScheduleRevoked(beneficiary, unvested);
    }

    // ──────────────────────────────────────────────────────────────────
    // Beneficiary — release
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Release all currently vested and unreleased tokens to the caller.
     *         Caller must be a registered beneficiary.
     */
    function release() external nonReentrant {
        _release(msg.sender);
    }

    /**
     * @notice Release vested tokens on behalf of a beneficiary.
     *         Callable by the beneficiary themselves or by the owner.
     *
     * @param beneficiary Target beneficiary.
     */
    function releaseFor(address beneficiary) external nonReentrant {
        require(
            msg.sender == beneficiary || msg.sender == owner(),
            "TVDVesting: unauthorized"
        );
        _release(beneficiary);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Amount of TVD releasable right now for a given beneficiary.
     */
    function releasable(address beneficiary) public view returns (uint256) {
        VestingSchedule storage s = schedules[beneficiary];
        if (s.totalAmount == 0 || s.revoked) return 0;
        return _vestedAmount(s) - s.releasedAmount;
    }

    /**
     * @notice Cumulative TVD vested so far (regardless of how much was claimed).
     */
    function vestedAmount(address beneficiary) external view returns (uint256) {
        VestingSchedule storage s = schedules[beneficiary];
        if (s.totalAmount == 0) return 0;
        return _vestedAmount(s);
    }

    /**
     * @notice Returns all registered beneficiary addresses.
     */
    function getBeneficiaries() external view returns (address[] memory) {
        return _beneficiaryList;
    }

    // ──────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────

    function _release(address beneficiary) internal {
        uint256 amount = releasable(beneficiary);
        require(amount > 0, "TVDVesting: nothing to release");

        schedules[beneficiary].releasedAmount += amount;
        token.safeTransfer(beneficiary, amount);

        emit TokensReleased(beneficiary, amount);
    }

    /**
     * @dev Linear vesting with cliff, resolved at 1-day granularity.
     *      Partial days are ignored: only fully elapsed days count toward
     *      the cliff and the linear release.
     *      Returns 0 while in cliff, totalAmount once fully vested,
     *      and a pro-rata amount in between.
     */
    function _vestedAmount(VestingSchedule storage s)
        internal
        view
        returns (uint256)
    {
        // Snap to the nearest complete day (floor).
        uint256 elapsed = ((block.timestamp - s.startTime) / 1 days) * 1 days;

        if (elapsed < s.cliffDuration) {
            return 0; // Still in cliff — nothing vested yet
        }

        uint256 postCliff = elapsed - s.cliffDuration;

        if (postCliff >= s.vestingDuration) {
            return s.totalAmount; // Fully vested
        }

        // Linear interpolation between cliff end and vesting end
        return (s.totalAmount * postCliff) / s.vestingDuration;
    }
}
