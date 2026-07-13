// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IVestingProvider
 * @notice Common interface for contracts that hold time-locked TVD on behalf
 *         of institutions and can supply tokens to TVDElectoralCredits.
 *
 * Implemented by:
 *   • TVDInstitutionalVesting  — fixed-lock institutional allocation
 *   • TVDIncentiveCampaigns    — campaign-based incentive pool
 *
 * ── Integration with TVDElectoralCredits ─────────────────────────────
 *
 *  topUp():
 *    1. TVDElectoralCredits calls assignedBalance(institution) on each provider.
 *    2. First provider with sufficient balance is selected.
 *    3. TVDElectoralCredits calls withdrawFor(institution, amount) on that provider.
 *       The provider transfers tokens directly to TVDElectoralCredits.
 *
 *  liquidate() — refund path:
 *    1. TVDElectoralCredits transfers unused tokens to the provider address.
 *    2. TVDElectoralCredits calls creditRefund(institution, amount) to update
 *       the provider's internal accounting.
 */
interface IVestingProvider {
    /// @notice Amount of TVD currently assigned to `institution` in this provider.
    function assignedBalance(address institution) external view returns (uint256);

    /// @notice Pull `amount` of TVD from the provider to the caller (TVDElectoralCredits).
    ///         Only callable by the authorised TVDElectoralCredits contract.
    function withdrawFor(address institution, uint256 amount) external;

    /// @notice Restore `amount` of TVD to `institution` after a liquidation refund.
    ///         The caller (TVDElectoralCredits) must transfer the tokens to this
    ///         contract BEFORE calling this function.
    ///         Only callable by the authorised TVDElectoralCredits contract.
    function creditRefund(address institution, uint256 amount) external;
}
