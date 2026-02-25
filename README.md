# Vote Contracts

An anonymous on-chain voting system powered by **zero-knowledge proofs**. Voters prove their eligibility without revealing their identity, ensuring ballot secrecy while preventing double voting.

## Overview

The `VoteManager` contract leverages [iden3](https://iden3.io/)'s **EmbeddedZKPVerifier** to verify zero-knowledge proofs on-chain. Each voter submits a ZK proof that attests to their eligibility, and a nullifier that prevents them from voting twice — all without linking a vote to a specific identity.

### Key Features

- **Anonymous voting** — ZK proofs decouple identity from vote, preserving voter privacy.
- **Double-vote prevention** — Unique nullifiers ensure each eligible voter can only vote once per election.
- **Configurable lifecycle** — Each vote has distinct start, end, and results-release dates.
- **On-chain results** — Vote tallies are stored on-chain and become publicly queryable after the results date.
- **Upgradeable** — Built on OpenZeppelin's `Initializable` and upgradeable proxy pattern.
- **Reentrancy-safe** — Uses OpenZeppelin's `ReentrancyGuardTransient` for the vote-casting flow.

### Contract Functions

| Function | Description |
|---|---|
| `setZKPRequest` | Set a new ZKP request with a given request ID |
| `createVote` | Create a new vote with options, dates, and a ZKP request ID. |
| `updateVoteDates` | Modify vote dates (only allowed ≥ 24 h before the start date). |
| `submitZKPResponse` | Submit a ZKP proof verification before cast vote |
| `castVote` | Cast an anonymous vote after ZK proof verification. |
| `getVoteResults` | Retrieve tallied results (available only after the results date). |
| `getOwnVoteInfo` | Check your own vote using your nullifier. |

### How It Works

1. An admin creates a vote via `createVote`, specifying options and a ZKP request ID.
2. Voters generate a ZK proof off-chain using the iden3 protocol.
3. The proof is submitted and verified on-chain by the `EmbeddedZKPVerifier`.
4. The voter calls `castVote` with their chosen option and a nullifier.
5. After the results date, anyone can call `getVoteResults` to view the tally.

## Tech Stack

- **Solidity ^0.8.13**
- **Foundry** (Forge, Cast, Anvil)
- **iden3 contracts** — ZKP verification (`EmbeddedZKPVerifier`, `ICircuitValidator`)
- **OpenZeppelin** — Upgradeable proxies, reentrancy guards

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Deploy

```shell
forge script script/VoteManager.s.sol:VoteManagerScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Local Node

```shell
anvil
```
