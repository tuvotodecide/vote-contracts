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
 */
contract TVDToken is ERC20, ERC20Burnable, ERC20Capped, AccessControl {
    /// @notice Absolute maximum supply: 21,000,000 TVD (18 decimals).
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;

    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event InitialDistribution(
        address indexed liquidityWallet,
        address indexed treasuryWallet,
        address indexed ecosystemWallet,
        address vestingContract
    );

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
        address liquidityWallet,
        address treasuryWallet,
        address ecosystemWallet,
        address vestingContract,
        address admin
    ) ERC20("Tu Voto Decide", "TVD") ERC20Capped(MAX_SUPPLY) {
        require(liquidityWallet != address(0),  "TVD: invalid liquidity wallet");
        require(treasuryWallet  != address(0),  "TVD: invalid treasury wallet");
        require(ecosystemWallet != address(0),  "TVD: invalid ecosystem wallet");
        require(vestingContract != address(0),  "TVD: invalid vesting contract");
        require(admin           != address(0),  "TVD: invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // ── Mint full TGE supply ─────────────────────────────────────
        _mint(liquidityWallet,  4_200_000 * 10 ** 18); // 20% — immediate
        _mint(treasuryWallet,   8_400_000 * 10 ** 18); // 40% — B2B treasury
        _mint(ecosystemWallet,  5_250_000 * 10 ** 18); // 25% — ecosystem
        _mint(vestingContract,  3_150_000 * 10 ** 18); // 15% — team vesting

        emit InitialDistribution(
            liquidityWallet,
            treasuryWallet,
            ecosystemWallet,
            vestingContract
        );
    }

    // ──────────────────────────────────────────────────────────────────
    // Required override — ERC20 + ERC20Capped share _update hook
    // ──────────────────────────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped)
    {
        super._update(from, to, value);
    }
}
