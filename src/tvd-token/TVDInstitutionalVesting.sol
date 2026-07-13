// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVestingProvider} from "./IVestingProvider.sol";

/**
 * @title  TVDInstitutionalVesting
 * @notice Time-locked TVD allocation for electoral institutions.
 *
 * ── Flow ─────────────────────────────────────────────────────────────
 *
 *  1. FUNDING
 *     Owner transfers TVD tokens directly to this contract address.
 *
 *  2. ASSIGNMENT
 *     Owner calls assign(institution, amount) to earmark tokens to a
 *     specific institution.  Total assigned may not exceed the contract
 *     balance.
 *
 *  3. ELECTORAL USE  (TVDElectoralCredits only)
 *     TVDElectoralCredits calls withdrawFor(institution, amount) during
 *     topUp to pull tokens into itself.  On liquidation, it transfers the
 *     unused tokens back here and calls creditRefund(institution, amount)
 *     to restore the institution's balance.
 *
 *  4. RELEASE  (institution, after lock expires)
 *     After block.timestamp >= startTime + duration, an institution may
 *     call release() to withdraw their full remaining assigned balance.
 *
 * ── Security notes ───────────────────────────────────────────────────
 *  • Only the authorised TVDElectoralCredits contract may call
 *    withdrawFor() and creditRefund().
 *  • creditRefund() only updates accounting; the token transfer is
 *    performed by TVDElectoralCredits before the call (CEI-safe).
 *  • totalAssigned tracks the sum of all assigned balances, preventing
 *    the owner from over-assigning beyond the held balance.
 */
contract TVDInstitutionalVesting is Ownable, ReentrancyGuard, IVestingProvider {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract.
    IERC20 public immutable token;

    /// @notice Address authorized to assign tokens.
    address public operator;

    /// @notice Unix timestamp when the lock period begins.
    uint256 public immutable startTime;

    /// @notice Lock duration in seconds after startTime.
    uint256 public duration;

    /// @notice TVDElectoralCredits contract authorised to withdraw and refund.
    address public creditsContract;

    /// @notice TVD balance assigned to each institution.
    mapping(address => uint256) public assignedBalance;

    /// @notice Sum of all assignedBalance values (over-assignment guard).
    uint256 public totalAssigned;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event OperatorSet(address indexed oldOperator, address indexed newOperator);
    event TokensAssigned(address indexed institution, uint256 amount);
    event TokensWithdrawn(address indexed institution, uint256 amount);
    event TokensRefunded(address indexed institution, uint256 amount);
    event TokensReleased(address indexed institution, uint256 amount);
    event CreditsContractSet(address indexed oldContract, address indexed newContract);

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyCreditsContract() {
        require(msg.sender == creditsContract, "TVDInstVesting: caller is not credits contract");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "TVDInstVesting: caller is not operator");
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token      TVDToken address.
     * @param _admin      Owner / admin multisig.
     * @param _operator   Authorized for no-multisig functions
     * @param _startTime  Unix timestamp when the lock period begins.
     */
    constructor(address _token, address _admin, address _operator, uint256 _startTime) Ownable(_admin) {
        require(_token != address(0), "TVDInstVesting: invalid token");
        require(_startTime > 0, "TVDInstVesting: invalid startTime");
        require(_operator != address(0), "TVDInstVesting: invalid operator");

        token = IERC20(_token);
        startTime = _startTime;
        operator = _operator;
        duration = 365 days; // 1 year lock default
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — configuration
    // ──────────────────────────────────────────────────────────────────

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "TVDInstVesting: invalid operator");
        emit OperatorSet(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Set or update the authorised TVDElectoralCredits contract.
     * @param _creditsContract Address of the TVDElectoralCredits contract.
     */
    function setCreditsContract(address _creditsContract) external onlyOwner onlyOperator {
        require(_creditsContract != address(0), "TVDInstVesting: invalid address");
        emit CreditsContractSet(creditsContract, _creditsContract);
        creditsContract = _creditsContract;
    }

    /**
     * @notice Set the lock duration for tokens.
     * @param _duration Duration in seconds.
     */
    function setDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "TVDInstVesting: duration must be > 0");
        duration = _duration;
    }

    /**
     * @notice Assign tokens to an institution.
     *
     * @dev    The contract must already hold enough unassigned tokens.
     *         Transfer TVD to this contract before calling assign().
     *
     * @param institution Address of the institution.
     * @param amount      Amount of TVD (wei) to assign.
     */
    function assign(address institution, uint256 amount) external onlyOperator {
        require(institution != address(0), "TVDInstVesting: invalid institution");
        require(amount > 0, "TVDInstVesting: amount must be > 0");

        uint256 newTotal = totalAssigned + amount;
        require(token.balanceOf(address(this)) >= newTotal, "TVDInstVesting: insufficient contract balance");

        assignedBalance[institution] += amount;
        totalAssigned = newTotal;

        emit TokensAssigned(institution, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Credits contract — integration
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Transfer tokens to TVDElectoralCredits on behalf of an institution.
     *         Called by TVDElectoralCredits during topUp.
     *
     * @param institution Address of the institution.
     * @param amount      Amount of TVD to withdraw.
     */
    function withdrawFor(address institution, uint256 amount) external nonReentrant onlyCreditsContract {
        require(assignedBalance[institution] >= amount, "TVDInstVesting: insufficient balance");

        assignedBalance[institution] -= amount;
        totalAssigned -= amount;

        token.safeTransfer(creditsContract, amount);

        emit TokensWithdrawn(institution, amount);
    }

    /**
     * @notice Credit refunded tokens back to an institution's assigned balance.
     *
     * @dev    TVDElectoralCredits transfers tokens directly to this contract
     *         (via token.safeTransfer) BEFORE calling this function, then calls
     *         this to update accounting.  No token transfer happens here.
     *
     * @param institution Address of the institution.
     * @param amount      Amount of TVD being credited back.
     */
    function creditRefund(address institution, uint256 amount) external onlyCreditsContract {
        require(institution != address(0), "TVDInstVesting: invalid institution");

        assignedBalance[institution] += amount;
        totalAssigned += amount;

        emit TokensRefunded(institution, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Institution — release
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Release the caller's entire assigned balance.
     *         Only callable after startTime + duration.
     */
    function release() external nonReentrant {
        require(block.timestamp >= startTime + duration, "TVDInstVesting: tokens are still locked");

        uint256 amount = assignedBalance[msg.sender];
        require(amount > 0, "TVDInstVesting: no tokens to release");

        assignedBalance[msg.sender] -= amount;
        totalAssigned -= amount;

        token.safeTransfer(msg.sender, amount);

        emit TokensReleased(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /// @notice Unix timestamp when tokens become releasable.
    function unlockTime() external view returns (uint256) {
        return startTime + duration;
    }

    /// @notice True if the lock period has passed.
    function isUnlocked() external view returns (bool) {
        return block.timestamp >= startTime + duration;
    }
}
