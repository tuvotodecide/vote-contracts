// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title  TVDToken
 * @notice Native ERC-20 token of the "Tu Voto Decide" platform.
 *
 * Hard cap: 21,000,000 TVD (immutable, algorithmically programmed).
 * The entire supply is minted at deployment (TGE) and distributed to
 * four designated wallets according to the SaaS tokenomics:
 *
 *  ┌────────────────────────┬──────┬────────────────┐
 *  │ Bucket                 │  %   │   Amount (TVD) │
 *  ├────────────────────────┼──────┼────────────────┤
 *  │ Liquidity (Exchanges)  │ 20%  │   4,200,000    │
 *  │ Treasury & B2B         │ 40%  │   8,400,000    │
 *  │ Ecosystem & Voters     │ 25%  │   5,250,000    │
 *  │ Team & Advisors        │ 15%  │   3,150,000    │
 *  └────────────────────────┴──────┴────────────────┘
 *
 * The token is purely deflationary: tokens can be burned but never
 * re-minted (no MINTER_ROLE). Only the DEFAULT_ADMIN_ROLE holder
 * may grant/revoke roles for future governance needs.
 *
 * Transfer lockup:
 * Individual addresses (e.g. team/advisor wallets) can be flagged via
 * `applyLockup` so that, until `lockupEnd`, they may only send tokens to
 * addresses holding LOCKUP_BYPASS_ROLE (e.g. a vesting or credits contract).
 * Addresses not flagged, or transfers made after `lockupEnd`, are unaffected.
 *  - LOCKUP_MANAGER_ROLE: may flip `applyLockup` for any address.
 *  - LOCKUP_BYPASS_ROLE:  may receive tokens from a locked address before
 *                         `lockupEnd`.
 */
contract TVDToken is ERC20, ERC20Burnable, ERC20Capped, AccessControl {
    /// @notice Absolute maximum supply: 21,000,000 TVD (18 decimals).
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;
    /// @notice Timestamp after which the transfer lockup no longer applies.
    uint256 public lockupEnd;
    /// @notice Addresses whose outgoing transfers are restricted until `lockupEnd`.
    mapping(address => bool) applyLockup;

    /// @notice Role allowed to toggle which addresses are subject to the lockup.
    bytes32 public constant LOCKUP_MANAGER_ROLE = keccak256("LOCKUP_MANAGER_ROLE");
    /// @notice Role allowed to receive tokens from locked addresses before lockupEnd.
    bytes32 public constant LOCKUP_BYPASS_ROLE = keccak256("LOCKUP_BYPASS_ROLE");

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event InitialDistribution(
        address indexed liquidityWallet,
        address indexed treasuryWallet,
        address indexed ecosystemWallet,
        address vestingContract
    );

    event ApplyLockupUpdated(address indexed account, bool locked);

    event LockupEndUpdated(uint256 previousLockupEnd, uint256 newLockupEnd);

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param liquidityWallet  Receives 20 % (4,200,000 TVD) — immediately
     *                         available for DEX liquidity at TGE.
     * @param treasuryWallet   Receives 40 % (8,400,000 TVD) — controlled by a
     *                         multisig for B2B expansion and sandbox pilots.
     * @param ecosystemWallet  Receives 25 % (5,250,000 TVD) — "Vota y Gana"
     *                         programme and ZK-KYC airdrops.
     * @param vestingContract  Receives 15 % (3,150,000 TVD) — held by the
     *                         TVDVesting contract for team/advisor cliff+vesting.
     * @param admin            Address granted DEFAULT_ADMIN_ROLE (governance).
     */
    constructor(
        uint256 _lockupEnd,
        address liquidityWallet,
        address treasuryWallet,
        address ecosystemWallet,
        address vestingContract,
        address admin
    ) ERC20("Tu Voto Decide", "TVD") ERC20Capped(MAX_SUPPLY) {
        require(liquidityWallet != address(0), "TVD: invalid liquidity wallet");
        require(treasuryWallet != address(0), "TVD: invalid treasury wallet");
        require(ecosystemWallet != address(0), "TVD: invalid ecosystem wallet");
        require(vestingContract != address(0), "TVD: invalid vesting contract");
        require(admin != address(0), "TVD: invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // ── Mint full TGE supply ─────────────────────────────────────
        _mint(liquidityWallet, 4_200_000 * 10 ** 18); // 20% — immediate
        _mint(treasuryWallet, 8_400_000 * 10 ** 18); // 40% — B2B treasury
        _mint(ecosystemWallet, 5_250_000 * 10 ** 18); // 25% — ecosystem
        _mint(vestingContract, 3_150_000 * 10 ** 18); // 15% — team vesting
        lockupEnd = _lockupEnd;

        emit InitialDistribution(liquidityWallet, treasuryWallet, ecosystemWallet, vestingContract);
    }

    /**
     * @notice Marks whether `account` is subject to the transfer lockup.
     * @param account Address to update.
     * @param locked  True to subject the address to the lockup, false to exempt it.
     */
    function setApplyLockup(address account, bool locked) external onlyRole(LOCKUP_MANAGER_ROLE) {
        applyLockup[account] = locked;
        emit ApplyLockupUpdated(account, locked);
    }

    /**
     * @notice Updates the timestamp after which the transfer lockup no longer applies.
     * @param newLockupEnd New lockup-end timestamp.
     */
    function setLockupEnd(uint256 newLockupEnd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit LockupEndUpdated(lockupEnd, newLockupEnd);
        lockupEnd = newLockupEnd;
    }

    /**
     * @dev While `from` is flagged in `applyLockup` and `lockupEnd` hasn't
     *      passed, the transfer is only allowed if `to` holds
     *      LOCKUP_BYPASS_ROLE. Mints, burns and unflagged senders bypass
     *      this check entirely.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        if (applyLockup[from] && block.timestamp < lockupEnd) {
            require(hasRole(LOCKUP_BYPASS_ROLE, to), "tokens are still locked");
        }
        super._update(from, to, value);
    }
}
