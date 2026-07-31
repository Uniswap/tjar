# tjar — repo context

The Uniswap protocol fee collection system. Foundry / Solidity
`^0.8.29`, built on solmate (`Owned`, `ERC20`, `SafeTransferLib`),
v4-core's `Currency` type, and `@eth-optimism-bedrock` predeploys.

The contracts are **immutable and already deployed** to Ethereum mainnet
and Unichain (addresses are in README.md). There is no proxy and no
upgrade path. A bug that ships is fixed by deploying a new contract and
re-pointing governance at it — not by a patch. Four audits live under
`audit/` (Cantina, OpenZeppelin ×3).

## The three layers

| Layer | What it is |
|---|---|
| **TokenJar** (`src/TokenJar.sol`) | One per chain. Passive fee sink. Holds arbitrary assets. Exactly one privileged role, `releaser`, which may sweep full balances. `owner` sets the releaser. |
| **Fee sources** | Adapters that route protocol fees into the local TokenJar. Push (V2 mints LP tokens straight to the jar) or pull (V3/V4 need a permissionless collection call). Not all of them live in this repo. |
| **Releasers** (`src/releasers/`) | The contract installed as a jar's `releaser`. Implements what the fees are exchanged *for*. |

## The exchange, precisely

`ExchangeReleaser.release(uint256 _nonce, Currency[] assets, address recipient)`
is **permissionless** — any searcher may call it. In order:

1. `handleNonce(_nonce)` requires `_nonce == nonce` exactly, then
   `unchecked { ++nonce; }` **before** the function body runs.
2. `require(assets.length <= MAX_RELEASE_LENGTH)` — the cap is 20.
3. `RESOURCE.safeTransferFrom(msg.sender, RESOURCE_RECIPIENT, threshold)`
   — pulls the fixed resource amount (UNI) from the caller.
4. `TOKEN_JAR.release(assets, recipient)` — the jar loops the assets,
   reads `balanceOfSelf()`, and transfers the **entire** balance of each
   to `recipient`, skipping zero balances.
5. `emit Released(...)`, then the `_afterRelease` hook.

Concrete subclasses:

- **`Firepit`** — `RESOURCE_RECIPIENT = address(0xdead)`. UNI is burned by
  direct transfer. `_afterRelease` is the inherited no-op.
- **`OptimismBridgedResourceFirepit`** — `RESOURCE_RECIPIENT = address(this)`,
  because bridged UNI can't be burned on L2 in one step. `_afterRelease`
  calls `L2StandardBridge.withdrawTo(address(RESOURCE), 0xdead, threshold,
  WITHDRAWAL_MIN_GAS /* 100_000 */, "")`. Stage 2 finalizes on L1 only
  after the challenge period.

The searcher's profit is `value(released assets) - value(threshold UNI) - gas`.
That spread is the entire coordination mechanism: nobody schedules a
release, economics do.

## Standing invariants

- **Full-balance, all-or-nothing transfers.** The jar never does partial
  amounts. A change introducing a partial or caller-specified amount is a
  design change, not a refactor.
- **Sequential nonce.** The nonce exists so a searcher who sees a
  profitable jar state can claim it without being front-run. Because it
  increments inside the modifier, a revert anywhere later in the call
  unwinds the increment — a failed release does not consume a nonce.
  Anything that makes nonces skippable, parallel, or caller-chosen breaks
  the front-running guarantee.
- **Immutables are immutable.** `TOKEN_JAR`, `RESOURCE`, and
  `RESOURCE_RECIPIENT` are `immutable`; `MAX_RELEASE_LENGTH` is
  `constant`. Adding a setter for any of them converts a
  redeploy-and-govern change into a hot-swap and is a `critical` finding
  unless the PR is explicitly about that.
- **Only `threshold` is meant to move**, and only via `thresholdSetter`
  (which `owner` assigns; it is `address(0)` until then, so
  `setThreshold` reverts on a fresh deployment until wired). `threshold`
  is a live economic parameter — changing it re-prices every in-flight
  searcher transaction.
- **Two privilege ladders, don't conflate them.** On the jar:
  `owner → setReleaser`. On the releaser: `owner → setThresholdSetter`,
  `thresholdSetter → setThreshold`. `release` itself is on neither ladder.

## Hostile tokens are in scope

`TokenJar.release` iterates a **caller-supplied** asset array and calls
into each token. The test suite has dedicated mocks for this —
`test/mocks/RevertingToken.sol`, `RevertBombToken.sol`, `OOGToken.sol` —
so token misbehavior is a first-class concern, not a hypothetical.

Reason about it from the right threat model: the caller is the searcher,
who is also paying. A searcher who includes a reverting token grief only
their own transaction. The sharper questions are whether a token *already
sitting in the jar* can block releases that omit it, whether a
`balanceOfSelf`/`transfer` mismatch (fee-on-transfer, rebasing) leaves
value stranded or over-released, and whether the 20-asset cap plus
`WITHDRAWAL_MIN_GAS` leave enough gas headroom for the bridge call in the
worst case.

## Things that look wrong but aren't

- **No reentrancy guard on `TokenJar.release`.** It is `onlyReleaser`, and
  the releaser is a known contract. Note it if a PR widens who can call
  it, not otherwise.
- **`receive() external payable {}` with no logic.** The jar is
  deliberately a passive sink for native value.
- **The deployer is the initial `owner` of `TokenJar`.** The constructor
  comment states the deployer is expected to set the releaser and then
  transfer ownership. That's a deployment-procedure concern, not a
  contract bug.
- **`thresholdSetter` starting at `address(0)`.** Documented and
  intentional; the owner wires it post-deploy.
- **A releaser that ignores `assets` and `recipient` in `_afterRelease`.**
  `OptimismBridgedResourceFirepit` discards both parameters — it bridges
  `threshold`, which has nothing to do with which fee assets moved.
- **`unchecked { ++nonce; }`.** A `uint256` nonce cannot realistically
  overflow. Don't file it.
- **Zero-balance assets silently skipped.** `if (amount > 0)` is the
  design, and it makes duplicate entries in the array harmless.
- **Generated/vendored code under `lib/`.** Foundry submodules. Not ours
  to review.

## What's invisible from a single PR

- **Deployed bytecode does not change when `src/` changes.** A fix in
  this repo does nothing until a new deployment plus a governance action
  re-points the jar's `releaser`. If a PR presents itself as fixing a
  live issue, the deployment and governance path is part of the change —
  ask for it.
- **README deployed addresses and parameters** (`threshold` 2000 UNI,
  `WITHDRAWAL_MIN_GAS` 100,000) are documentation of on-chain state.
  A code change that contradicts them needs both updated, and the
  README is not the source of truth for what is live.
- **Audited code paths.** `audit/` covers a specific version. A diff that
  changes reviewed behavior expands re-audit scope — worth saying out
  loud in the review even when the code is correct.
- **Fee sources live partly elsewhere.** The jar accepts value from
  adapters that may not be in this repo, so "which assets can appear in
  the jar" is not answerable from this diff alone. Don't assume the set
  is closed.
- **OP Stack bridge assumptions.** `Predeploys.L2_STANDARD_BRIDGE` and
  `OptimismMintableERC20` semantics are inherited from upstream Optimism
  contracts. A chain that deviates breaks stage 2 silently — the L2 side
  still succeeds.

## Review posture

Match the bar to the blast radius. This is deployed, immutable, audited
code that custodies protocol fees, so a real finding in `src/` is worth
being direct and blunt about. Equally: the codebase is intentionally
small and plain, and structural or stylistic advice on a 45-line contract
is noise. Silence on a clean diff is the correct output.
