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

### Base & interfaces

- [`ResourceManager.sol`](src/base/ResourceManager.sol) — defines the `RESOURCE` token and the `threshold` amount required per release.
- [`Nonce.sol`](src/base/Nonce.sol) — sequences pending releases to prevent front-running.
- [`src/interfaces/`](src/interfaces/) — [`ITokenJar`](src/interfaces/ITokenJar.sol), [`IReleaser`](src/interfaces/IReleaser.sol), and base interfaces (`IResourceManager`, `INonce`, `IOwned`), plus the external `IL2StandardBridge`.

## Economic Incentives

Redemption is permissionless and competitive: a redeemer profits whenever the value of the assets accumulated in the Token Jar exceeds the fixed `RESOURCE` cost of a release. This means no manual intervention, keeper network, or price oracle is required — economic actors collect and convert fees on their own schedule purely for profit. Fixed redemption amounts limit MEV extraction, and sequential nonces make ordering deterministic.

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
├── base
│   ├── Nonce.sol                       // Sequences pending releases to prevent front-running
│   └── ResourceManager.sol             // Defines the RESOURCE token and release threshold
├── interfaces
│   ├── ITokenJar.sol
│   ├── IReleaser.sol
│   ├── base/                           // INonce, IOwned, IResourceManager
│   └── external/IL2StandardBridge.sol
└── releasers
    ├── ExchangeReleaser.sol            // Abstract: exchange RESOURCE for Token Jar assets
    ├── Firepit.sol                     // Burns RESOURCE directly (RESOURCE_RECIPIENT = 0xdead)
    └── OptimismBridgedResourceFirepit.sol // Two-stage burn for OP Stack L2s via bridge withdrawal

test
├── TokenJar.t.sol
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
