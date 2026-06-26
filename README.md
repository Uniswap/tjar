# TJAR — Token Jar + Releaser

*Scalable, general-purpose infrastructure for accumulating fees and redeeming them for a revenue token.*

> **Derivative notice**
> This repository is a derivative of [Uniswap/protocol-fees](https://github.com/Uniswap/protocol-fees) at the [`unification-proposal`](https://github.com/Uniswap/protocol-fees/tree/unification-proposal) ref, **pruned to the TJAR scope** — the Token Jar and Releaser contracts and their supporting base/interfaces.
>
> Everything specific to the Uniswap fee rollout — the V3 fee adapter, Merkle generator, deployers, deploy scripts, UNI vesting, the EAS agreement-anchor signing flow, and the governance proposal — has been removed. For the canonical Uniswap deployment, governance proposal, and fee adapters, see the upstream repository.

## Overview

The **Token Jar + Releaser** pattern is a reusable primitive: an immutable contract (the **Token Jar**) that accumulates arbitrary assets from any number of fee sources, and a **Releaser** that lets anyone atomically redeem those accumulated assets in exchange for a designated *revenue token* (the `RESOURCE`).

While it originated as Uniswap's protocol-fee mechanism (accumulate fees → redeem for UNI → burn the UNI), the pattern is broadly useful beyond Uniswap. Any system that collects fees in heterogeneous assets and wants to convert them into a single token — whether to burn it, distribute it, or route it to a treasury — can use this infrastructure unchanged. The Token Jar is agnostic about where assets come from; the Releaser is agnostic about what the revenue token is or what happens to it.

```
Fee Sources → Token Jar → Releaser → (redeemer pays RESOURCE) → RESOURCE_RECIPIENT
                                                  └→ optional protocol fee → FeeController.feeRecipient
```

## Architecture

### Token Jar

[`TokenJar.sol`](src/TokenJar.sol) is an immutable collection point. It receives assets (native or ERC-20) from any source and exposes a single privileged role, the `releaser`, which is the only address permitted to withdraw. Withdrawals are **atomic full-balance transfers** of the specified assets to a recipient.

- **Universal collector** — accepts fees from arbitrary sources
- **Single admin** — only the `releaser` can move assets out
- **Atomic** — releases the full balance of the specified assets

### Releasers

Releasers serve as the Token Jar's `releaser` and implement the redemption logic. They are built on a shared abstract base:

- [`ExchangeReleaser.sol`](src/releasers/ExchangeReleaser.sol) — abstract base. A redeemer pays a fixed `threshold` amount of the `RESOURCE` token and, in exchange, the Token Jar's accumulated assets are released to a recipient they specify. Subclasses decide what happens to the collected `RESOURCE` by setting `RESOURCE_RECIPIENT`. Sequential nonces (see [`Nonce.sol`](src/base/Nonce.sol)) prevent front-running and enforce deterministic ordering.
- [`Firepit.sol`](src/releasers/Firepit.sol) — concrete releaser that **burns** the `RESOURCE` by setting `RESOURCE_RECIPIENT = 0xdead`. On a chain where the revenue token is native (e.g. UNI on Ethereum mainnet), redemption directly burns it.
- [`OptimismBridgedResourceFirepit.sol`](src/releasers/OptimismBridgedResourceFirepit.sol) — concrete releaser for OP Stack L2s where only a bridged form of the revenue token exists. It implements a two-stage burn: collected tokens are held on L2, then an `_afterRelease()` hook initiates an L2→L1 bridge withdrawal via the [L2 Standard Bridge](src/interfaces/external/IL2StandardBridge.sol). After the bridge's challenge period, the underlying token is delivered to `0xdead` on L1.

### Protocol Fee

[`FeeController.sol`](src/FeeController.sol) is a chain-wide singleton holding an **optional protocol fee** charged *on top of* a release's `threshold`. It is independent of any individual Releaser: Releasers are designed to hold an immutable reference to it and read its configuration when pricing a release, so the fee can be changed in one place without touching partner contracts.

- **On top of the threshold** — `threshold` stays the partner's net amount; the fee is `threshold * feeBps / 10_000`, paid by the redeemer in the current `RESOURCE`. It starts at **0 bps**, so there is no fee by default.
- **Capped** — `feeBps` can never exceed `MAX_FEE_BPS` (1000 bps = 10%), a compile-time constant.
- **Atomic read** — `feeConfig()` returns `(feeBps, feeRecipient)` in a single call, so redeemers and Releasers always price against consistent state.
- **Governance-owned** — the owner is intended to be the **Uniswap governance address**; only it can change the fee or recipient. Partners cannot zero it out.
- **Fee recipient** — intended to be the **Uniswap Token Jar address**, so protocol fees accumulate alongside Uniswap's own fees and are redeemed through Uniswap's own Releaser. A non-zero fee cannot be enabled until a recipient is set.
- **Deterministic** — deployed once per chain at the same address via CREATE2 (no constructor args); the owner and recipient are configured post-deploy.

### Base & interfaces

- [`ResourceManager.sol`](src/base/ResourceManager.sol) — defines the `RESOURCE` token and the `threshold` amount required per release.
- [`Nonce.sol`](src/base/Nonce.sol) — sequences pending releases to prevent front-running.
- [`src/interfaces/`](src/interfaces/) — [`ITokenJar`](src/interfaces/ITokenJar.sol), [`IReleaser`](src/interfaces/IReleaser.sol), [`IFeeController`](src/interfaces/IFeeController.sol), and base interfaces (`IResourceManager`, `INonce`, `IOwned`), plus the external `IL2StandardBridge`.

## Economic Incentives

Redemption is permissionless and competitive: a redeemer profits whenever the value of the assets accumulated in the Token Jar exceeds the `RESOURCE` cost of a release — the partner's `threshold` plus any protocol fee. This means no manual intervention, keeper network, or price oracle is required — economic actors collect and convert fees on their own schedule purely for profit. Fixed redemption amounts limit MEV extraction, and sequential nonces make ordering deterministic.

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/)

### Installation

```bash
git clone https://github.com/Uniswap/tjar
cd tjar

# Install submodule dependencies
forge install

# Build
forge build
```

### Testing

```bash
forge test            # run all tests
forge test -vvv       # verbose
forge coverage        # coverage report
```

### Project Structure

```
src/
├── TokenJar.sol                        // Accumulates fees; only the releaser can withdraw
├── FeeController.sol                    // Chain-wide singleton holding the optional protocol fee
├── base
│   ├── Nonce.sol                       // Sequences pending releases to prevent front-running
│   └── ResourceManager.sol             // Defines the RESOURCE token and release threshold
├── interfaces
│   ├── ITokenJar.sol
│   ├── IReleaser.sol
│   ├── IFeeController.sol
│   ├── base/                           // INonce, IOwned, IResourceManager
│   └── external/IL2StandardBridge.sol
└── releasers
    ├── ExchangeReleaser.sol            // Abstract: exchange RESOURCE for Token Jar assets
    ├── Firepit.sol                     // Burns RESOURCE directly (RESOURCE_RECIPIENT = 0xdead)
    └── OptimismBridgedResourceFirepit.sol // Two-stage burn for OP Stack L2s via bridge withdrawal

test
├── TokenJar.t.sol
├── FeeController.t.sol
├── ExchangeReleaser.t.sol
├── Firepit.t.sol
├── OptimismBridgedResourceFirepit.t.sol
├── mocks/                              // mock tokens and releasers
└── utils/                             // shared test base
```

## Security

Audit reports are available in [audit/](./audit/):

- OpenZeppelin (`openzeppelin-1.pdf`, `openzeppelin-2.pdf`, `openzeppelin-3.pdf`)
- Cantina (`cantina.pdf`)

> Note: the audits cover the upstream Uniswap/protocol-fees code from which this repository is derived.

## License

AGPL-3.0-only.
