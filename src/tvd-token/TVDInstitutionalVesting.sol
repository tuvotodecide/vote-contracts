// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVestingProvider} from "./IVestingProvider.sol";
import {TVDToken} from "./TVDToken.sol";

/**
 * @title  TVDInstitutionalVesting
 * @notice Time-locked TVD transfers for electoral institutions.
 *
 * ── Flow ─────────────────────────────────────────────────────────────
 *
 *  1. FUNDING
 *     Owner transfers TVD tokens directly to this contract address.
 *
 *  2. ASSIGNMENT
 *     Owner calls assign(institution, amount) to transfer tokens to a
 *     specific institution and mark as locked in TVD token, the tokens
 *     assigned only can be used to post elections until lockups ends.
 */
contract TVDInstitutionalVesting is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    /// @notice TVDToken contract.
    TVDToken public immutable token;

    /// @notice Role authorized to assign tokens to institutions.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event TokensAssigned(address indexed institution, uint256 amount);
    event TokensRescued(address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _token      TVDToken address.
     * @param _admin      Address granted DEFAULT_ADMIN_ROLE (governance).
     * @param _operator   Address granted OPERATOR_ROLE (assign()).
     */
    constructor(address _token, address _admin, address _operator) {
        require(_token != address(0), "TVDInstVesting: invalid token");
        require(_admin != address(0), "TVDInstVesting: invalid admin");
        require(_operator != address(0), "TVDInstVesting: invalid operator");

        token = TVDToken(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    /**
     * @notice Assign tokens to an institution.
     *
     * @dev    The contract must already hold enough tokens.
     *         Transfer TVD to this contract before calling assign().
     *
     * @param institution Address of the institution.
     * @param amount      Amount of TVD (wei) to assign.
     */
    function assign(address institution, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(institution != address(0), "TVDInstVesting: invalid institution");
        require(amount > 0, "TVDInstVesting: amount must be > 0");
        require(token.balanceOf(address(this)) >= amount, "TVDInstVesting: insufficient contract balance");

        token.setApplyLockup(institution, true);
        IERC20(address(token)).safeTransfer(institution, amount);
        emit TokensAssigned(institution, amount);
    }

    /**
     * @notice Transfer TVD held by this contract to any address.
     *
     * @param to     Recipient address.
     * @param amount Amount of TVD (wei) to transfer.
     */
    function rescueTokens(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "TVDInstVesting: invalid recipient");
        require(amount > 0, "TVDInstVesting: amount must be > 0");
        require(token.balanceOf(address(this)) >= amount, "TVDInstVesting: insufficient contract balance");

        IERC20(address(token)).safeTransfer(to, amount);
        emit TokensRescued(to, amount);
    }
}
