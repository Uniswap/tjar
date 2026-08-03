# TJAR — Token Jar + Releaser

*Scalable, general-purpose infrastructure for accumulating fees and redeeming them for a revenue token.*

> **Derivative notice**
> This repository is a derivative of [Uniswap/protocol-fees](https://github.com/Uniswap/protocol-fees) at the [`unification-proposal`](https://github.com/Uniswap/protocol-fees/tree/unification-proposal) ref, **pruned to the TJAR scope** — the Token Jar and Releaser contracts and their supporting base/interfaces.
>
> Everything specific to the Uniswap fee rollout — the V3 fee adapter, Merkle generator, deployers, deploy scripts, UNI vesting, the EAS agreement-anchor signing flow, the governance proposal, and the Firepit burn releasers (`Firepit`, `OptimismBridgedResourceFirepit`) — has been removed. For the canonical Uniswap deployment, governance proposal, fee adapters, and Firepits, see the upstream repository.

## Overview

The **Token Jar + Releaser** pattern is a reusable primitive: an immutable contract (the **Token Jar**) that accumulates arbitrary assets from any number of fee sources, and a **Releaser** that lets anyone atomically redeem those accumulated assets in exchange for a designated *revenue token* (the `resource`).

While it originated as Uniswap's protocol-fee mechanism (accumulate fees → redeem for UNI → burn the UNI), the pattern is broadly useful beyond Uniswap. Any system that collects fees in heterogeneous assets and wants to convert them into a single token — whether to burn it, distribute it, or route it to a treasury — can use this infrastructure unchanged. The Token Jar is agnostic about where assets come from; the Releaser is agnostic about what the revenue token is or what happens to it.

```
Fee Sources → Token Jar → Releaser → (redeemer pays resource) → resourceRecipient
                                                 └→ optional protocol fee → FeeController.feeRecipient
```

## Architecture

### Token Jar

[`TokenJar.sol`](src/TokenJar.sol) is an immutable collection point. It receives assets (native or ERC-20) from any source and exposes a single privileged role, the `releaser`, which is the only address permitted to withdraw. Withdrawals are **atomic full-balance transfers** of the specified assets to a recipient.

- **Universal collector** — accepts fees from arbitrary sources
- **Single admin** — only the `releaser` can move assets out
- **Atomic** — releases the full balance of the specified assets

### Releasers

Releasers serve as the Token Jar's `releaser` and implement the redemption logic:

- [`ExchangeReleaser.sol`](src/releasers/ExchangeReleaser.sol) — the concrete, deployable releaser. A redeemer pays a fixed `threshold` amount of the `resource` token and, in exchange, the Token Jar's accumulated assets are released to a recipient they specify. The collected `resource` is forwarded to the `resourceRecipient`. Sequential nonces (see [`Nonce.sol`](src/base/Nonce.sol)) prevent front-running and enforce deterministic ordering. An `_afterRelease` hook stays virtual as the extension point for specialized variants.
- [`OptimismBridgedResourceReleaser.sol`](src/releasers/OptimismBridgedResourceReleaser.sol) — a variant for OP-stack L2s where the revenue token's meaningful destination lives on L1: e.g. a partner's L2 jar is cleared with bridged USDC and that USDC belongs in their mainnet operations wallet — or, for burn-style configs, at `0xdead`, since a local L2 transfer wouldn't burn the canonical token. It collects the `resource` at itself (`resourceRecipient` pinned to `address(this)`), then `_afterRelease` initiates an L2→L1 bridge withdrawal of its **full balance** to a configurable `l1ResourceRecipient` (settable by the owner or `configSetter`; changing it doesn't bump the nonce since it doesn't alter searcher terms). The `resource` is frozen after construction (a different bridged token means a fresh releaser and a jar rotation) and must be withdrawable through the standard bridge (an `OptimismMintableERC20` like USDC.e — not native CCTP USDC), which the constructor verifies; if the token ever *stops* being withdrawable (e.g. a bridged→native migration), releases revert and fees safely accumulate in the jar until the jar owner rotates to a fresh releaser. `threshold` and `maxReleaseLength` stay tunable through the usual atomic `setConfig`. Risk on the L1 leg: `l1ResourceRecipient` is mutable and rotating it redirects all future withdrawals immediately, but the bridge binds each already-initiated withdrawal to the recipient it was initiated with — so if that recipient cannot receive the token on L1 (e.g. blacklisted), those in-flight withdrawals sit in bridge escrow, replayable by anyone but never re-addressable. Revenue configs should prefer a small owner-controlled L1 forwarder as the recipient and rotate via `setL1ResourceRecipient` on first sign of trouble; for burn configs, escrowed is economically burned.

The release configuration — `resource`, `resourceRecipient`, `threshold`, `maxReleaseLength` — is mutable, but only **atomically**, through a single `setConfig` call. There are deliberately no per-field setters: `threshold` is denominated *in* `resource`, so sequential single-field updates would pass through intermediate configs that are validly releasable at their own nonce (e.g. a WETH threshold briefly expressed in USDC units). `setConfig` is callable by the owner or an appointed `configSetter`, and **every call bumps the release nonce** — a pending release priced against old terms reverts instead of executing against terms the caller never saw. Rotating the `configSetter` itself does not bump; it changes who may set terms, not the terms. The `resource` token's own behavior (upgrade, pause, blacklist, fee toggle) also sits outside the nonce guarantee and is trusted for the config's life — prefer immutable, non-upgradeable resources.

**Fee-on-transfer resources** — `release()` is send-denominated: the redeemer is debited exactly `threshold`, so a fee-on-transfer `resource` delivers `threshold × (1 − f)` to the `resourceRecipient` (the protocol-fee leg is shaved identically). Partners compensate by grossing up the config (`threshold = N / (1 − f)`) and re-tuning via `setConfig` if the token's fee ever changes. If exact delivery is ever worth enforcing on-chain, it belongs in a future receive-denominated `FotExchangeReleaser` variant (require the recipient's balance delta to reach `threshold`), adopted per partner through the standard [releaser rotation](#rotating-releasers) — not in the hot path of every deployment.

#### Burn configurations (what happened to Firepit)

Upstream `protocol-fees` ships **Firepit** releasers that burn the `RESOURCE` by hard-coding the recipient to `0xdead`. TJAR removed them: burning is a *configuration* of the Releaser, not a separate contract — and the immutability a hard-coded burn address appears to offer is weaker than it looks, because the Token Jar owner can always rotate to a different releaser via `setReleaser`. A burn commitment is a property of the whole system (Jar ownership *and* Releaser config), never of the Releaser alone.

(This holds for the bridged variant too: `OptimismBridgedResourceReleaser` exists for the *delivery behavior* — an L2→L1 withdrawal — and a canonical burn is, once again, just a configuration of it: `l1ResourceRecipient = 0xdead`.)

To replicate a Firepit in TJAR, pick the guarantee level you actually need:

1. **Burn economics** — deploy the Releaser with `resourceRecipient = 0xdead`. Every release burns the revenue token, but the owner retains control.
2. **Trust-minimized burn** — additionally place ownership of the Jar and the Releaser behind a timelock or governance, so any change of terms is slow and publicly visible.
3. **Trustless burn** — relinquish control entirely, deployable **atomically in one transaction**: `factory.deploy(..., owner: 0xdead, configSetter: address(0), ...)`. No key ever holds power over the pair, and nothing — recipient, threshold, or the jar↔releaser wiring — can ever change. The trade-off is a frozen `threshold`: if the revenue token's price drifts far enough, releases become over- or under-priced forever, with no way to retune. (An intermediate variant: `owner = 0xdead` with a live `configSetter` freezes the roles and wiring but keeps terms tunable by that fixed address.) Factory releasers read the FeeController on every release, so release *liveness* rests on protocol governance maintaining a payable fee config — fees buffer safely in the jar if it ever isn't.
4. **Exactly upstream semantics** (immutable burn recipient with a governance-tunable threshold) — deploy the audited Firepit from [Uniswap/protocol-fees](https://github.com/Uniswap/protocol-fees) itself. TJAR intentionally doesn't maintain a parallel copy.

### Protocol Fee

[`FeeController.sol`](src/FeeController.sol) is a chain-wide singleton holding an **optional protocol fee** charged *on top of* a release's `threshold`. It is independent of any individual Releaser: Releasers are designed to hold an immutable reference to it and read its configuration when pricing a release, so the fee can be changed in one place without touching partner contracts.

- **On top of the threshold** — `threshold` stays the partner's net amount; the fee is `threshold * feeBps / 10_000`, paid by the redeemer in the current `RESOURCE`. It starts at **0 bps**, so there is no fee by default.
- **Capped** — `feeBps` can never exceed `MAX_FEE_BPS` (1000 bps = 10%), a compile-time constant.
- **Atomic read** — `feeConfig()` returns `(feeBps, feeRecipient)` in a single call, so redeemers and Releasers always price against consistent state.
- **Governance-owned** — the owner is intended to be the **Uniswap governance address**; only it can change the fee or recipient. Partners cannot zero it out within a factory-deployed Releaser. Known limitation: a partner can rotate their jar to a custom releaser that skips the fee entirely — enforced at the business layer, not on-chain. A `feeRecipient` a resource refuses to pay (e.g. blacklisted) reverts releases; fees buffer safely in the jar, remedied by a resource change or releaser rotation.
- **Fee recipient** — intended to be **Uniswap's own protocol Token Jar**, redeemed through Uniswap's own (upstream Firepit) releaser. This is a *different* jar from the partner jar a releaser drains — never the releaser's own `TOKEN_JAR` — so the fee is paid outward rather than back into the jar being swept. This separation is enforced at the business layer, not on-chain: a `feeRecipient` pointed at a factory-released jar would let a redeemer who lists the `RESOURCE` among the released assets reclaim the fee in the same release. A non-zero fee cannot be enabled until a recipient is set.
- **Deterministic** — deployed once per chain at the same address via CREATE2; its only constructor arg (the initial owner) is passed identically on every chain, keeping the initcode — and therefore the address — chain-invariant.

#### Cross-chain deployment & ownership

The rule that governs everything here: whatever is in **initcode** must be byte-identical on every chain (that is what fixes a CREATE2 address), while anything in **storage** is free to differ per chain.

The FeeController is deployed on each chain through the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the same salt and the same `_owner` argument. The owner is an explicit constructor arg because `msg.sender` inside the constructor would be the deployer proxy itself, which can never call the setters — deploying with `Owned(msg.sender)` through this path would brick the contract. The `_owner` must be an address controlled on every chain: an EOA (automatic), or a deterministically deployed Safe.

The per-chain ceremony, all in one script run:

1. **Deploy** `FeeController(opsOwner)` — lands at the same address on every chain
2. **Configure** — `setFeeRecipient(uniswapTokenJar)`; the recipient is itself deterministically deployed, so this value is also chain-invariant
3. **Hand off** — `transferOwnership(<this chain's governance executor>)`: the Timelock on mainnet, the bridge executor Uniswap governance acts through on each L2. These differ per chain, which is fine — ownership is storage, not initcode.

Deploy order per chain is **FeeController → Factory → partner deployments**, since factory-deployed releasers call `feeConfig()` on every release. The window before governance handoff is low-risk by construction: the fee starts at 0 bps, is hard-capped at `MAX_FEE_BPS`, and cannot be non-zero until a recipient is set. One caution: `Owned.transferOwnership` is single-step, so verify each L2's governance executor address before sending — a transfer to the wrong alias is unrecoverable.

### Factory

[`Factory.sol`](src/Factory.sol) deploys partner TokenJar + ExchangeReleaser pairs and hands all authority to the partner:

```solidity
factory.deploy(revenueToken, revenueRecipient, threshold, owner, configSetter, salt) → (jar, releaser)
```

In a single transaction the Factory CREATE2-deploys the jar and the releaser (wired to the jar address, the initial config, and the FeeController), sets the releaser on the jar, transfers ownership of both contracts to `owner`, and appoints `configSetter` on the releaser (pass `address(0)` to leave the role unset). It emits `JarDeployed` (the initial config is covered by the releaser's own `ConfigSet` in the same transaction) and keeps **no registry and no residual authority** — the Factory can never touch a deployed pair again.

The two roles are independent because they only make sense as different addresses — the owner can always call `setConfig` directly, so the `configSetter` role exists for delegation (cold Safe as owner, warm ops key tuning terms). Since `setConfig` controls the `threshold` and `resourceRecipient`, choose it carefully and secure it accordingly. The combinations map to real configurations: `owner` + ops `configSetter` (the standard setup), `owner` + zero (owner-only config), `0xdead` + a live setter (roles and wiring frozen forever, terms still tunable by a fixed party), or `0xdead` + zero (**trustless from birth** — see the burn tiers above). A zero `owner` reverts; `0xdead` states relinquishment intent unambiguously.

- **Permissionless** — anyone can deploy; the Factory holds no privileges worth gating.
- **Sender-scoped salts** — the effective CREATE2 salt is `keccak256(msg.sender, salt)`. The TokenJar takes no constructor args (that is what makes its address chain-invariant), so an unscoped salt would let a griefer front-run a partner's deploy on another chain and squat their predicted jar address with a different admin. Scoping means an address is only reachable by the same deployer with the same salt — deploy from the same address on every chain and the jar lands at the same address everywhere.
- **Predictable** — `predictJar(deployer, salt)` returns the jar address before anything is deployed, so a partner can wire their fee sources (e.g. a TAPI integration) to it in advance. Wire *addresses* in advance, never funds — see the prefunding caution below.
- **Chain-invariant** — the Factory itself deploys through the canonical CREATE2 deployer, and its only constructor arg is the (chain-invariant) FeeController address, so the Factory sits at the same address on every chain.

**Prefunding caution** — deploy the jar (one cheap, permissionless transaction) *before* fees flow to its address. A predicted-but-undeployed address is reachable only through the canonical Factory on that chain and only by the same deployer identity, and neither assumption is enforceable on-chain: if the Factory never lands on a chain, funds sent early are stranded; and a contract-account deployer whose address does not commit its controller (e.g. a CREATE-based Safe recreatable on another chain, or a counterfactual account anyone can claim) lets an unintended party call `deploy()` as that sender and take the jar under their own owner. Deploy from an EOA for any salt reused across chains, and verify the Factory's code at its canonical address on each new chain before wiring anything.

#### Rotating releasers

A partner can move their jar to a new releaser (new terms, new config, or a specialized variant) in two steps, both under their own keys:

1. `factory.deployReleaser(jar, revenueToken, revenueRecipient, threshold, owner, configSetter, salt)` — deploys a fresh releaser pointed at the existing jar, owned by `owner`. It is **inert until adopted**: anyone can deploy a releaser at any jar, but an unadopted releaser cannot move a single asset.
2. `jar.setReleaser(newReleaser)` — the jar owner adopts it. When the admin is a Safe, both steps batch into one atomic transaction.

The Factory deliberately has **no power to redirect a jar** — `setReleaser` belongs solely to the jar owner, which keeps "the Factory retains no authority" true forever and jar ownership the system's only trust anchor. Once a rotation lands, a pending release against the old releaser reverts atomically (the jar rejects it before any asset moves), searchers re-simulate on the jar's `ReleaserSet` event, and the old releaser is harmlessly orphaned.

### Base & interfaces

- [`ResourceManager.sol`](src/base/ResourceManager.sol) — holds the release configuration (`resource`, `resourceRecipient`, `threshold`, `maxReleaseLength`, `configSetter`) and enforces the atomic-`setConfig` + nonce-bump invariants.
- [`Nonce.sol`](src/base/Nonce.sol) — sequences pending releases to prevent front-running.
- [`ReentrancyGuard.sol`](src/base/ReentrancyGuard.sol) — transient-storage (EIP-1153) reentrancy guard applied to `release` on both the Token Jar and the Releaser, blocking a malicious jar asset from re-entering mid-sweep.
- [`src/interfaces/`](src/interfaces/) — [`ITokenJar`](src/interfaces/ITokenJar.sol), [`IReleaser`](src/interfaces/IReleaser.sol), [`IFeeController`](src/interfaces/IFeeController.sol), [`IFactory`](src/interfaces/IFactory.sol), and base interfaces (`IResourceManager`, `INonce`, `IOwned`).

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
├── FeeController.sol                   // Chain-wide singleton holding the optional protocol fee
├── Factory.sol                         // Deploys jar + releaser pairs; hands all authority to the partner
├── base
│   ├── Nonce.sol                       // Sequences pending releases to prevent front-running
│   ├── ReentrancyGuard.sol             // Transient-storage reentrancy guard for release()
│   └── ResourceManager.sol             // Atomic release config (setConfig) + nonce-bump invariants
├── interfaces
│   ├── ITokenJar.sol
│   ├── IReleaser.sol
│   ├── IFeeController.sol
│   ├── IFactory.sol
│   ├── base/                           // INonce, IOwned, IResourceManager
│   └── external/                       // Vendored OP-stack interfaces (IL2StandardBridge, IOptimismMintableERC20)
└── releasers
    ├── ExchangeReleaser.sol            // Concrete: exchange resource for Token Jar assets
    └── OptimismBridgedResourceReleaser.sol // Bridges the collected resource to an L1 recipient

script
├── Deploy.s.sol                        // Deterministic FeeController + Factory deployment
├── HandoffFeeController.s.sol          // Per-chain governance handoff ceremony
└── README.md                           // Deploy runbook: invariants, order, env vars

test
├── TokenJar.t.sol
├── FeeController.t.sol
├── ExchangeReleaser.t.sol
├── Factory.t.sol
├── OptimismBridgedResourceReleaser.t.sol
├── Deploy.t.sol                        // Deployment-path tests (incl. mainnet-fork proxy test)
├── mocks/                              // mock tokens and releasers
└── utils/                              // shared test base
```

## Security

Audit reports are available in [audit/](./audit/):

- **OpenZeppelin — TJAR** ([`openzeppelin-tjar-diff.pdf`](audit/openzeppelin-tjar-diff.pdf)) — audit of the TJAR-specific changes (the diff against upstream: the pruning to TJAR scope plus the protocol fee, factory, atomic config, and bridged-releaser work). All findings have been remediated.
- **OpenZeppelin — upstream** (`openzeppelin-1.pdf`, `openzeppelin-2.pdf`, `openzeppelin-3.pdf`)
- **Cantina — upstream** (`cantina.pdf`)

> The three OpenZeppelin `-1/-2/-3` reports and the Cantina report cover the upstream Uniswap/protocol-fees code this repository is derived from. The **OpenZeppelin TJAR** report covers the changes made on top of it — see the derivative notice at the top of this README for what that diff includes.

## License

AGPL-3.0-only.
