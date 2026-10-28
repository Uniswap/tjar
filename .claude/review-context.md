# tjar — review context

TJAR is a Foundry/Solidity `^0.8.29` system for accumulating arbitrary assets in a
`TokenJar` and allowing permissionless searchers to exchange a configured resource token for
those assets. It uses solmate, Uniswap v4's `Currency` type, and a small vendored OP Stack
bridge interface.

The contracts are non-upgradeable. The Factory and FeeController are deployed at deterministic
addresses on Ethereum, Optimism, BNB Chain, Polygon, Base, Arbitrum, and Robinhood Chain. Source changes do
not alter those deployments; a behavioral fix requires a new deployment and, where applicable,
a jar-owner or governance action. The reports under `audit/` cover specific historical commits.

## System boundaries

| Component | Authority and responsibility |
|---|---|
| `Factory` | Permissionlessly deploys `TokenJar` + `ExchangeReleaser` pairs or standalone releasers. It keeps no registry or authority after deployment. |
| `FeeController` | Protocol-owned singleton. Its owner sets the global fee rate and recipient; the rate is capped at 1,000 bps. |
| `TokenJar` | Passive asset sink. Its owner selects one `releaser`; only that address can sweep selected full balances. |
| `ExchangeReleaser` | Permissionless fixed-price exchange. Its owner or `configSetter` controls the release configuration. |
| `OptimismBridgedResourceReleaser` | OP Stack variant that collects the resource locally and bridges its full balance to an L1 recipient. |

The Factory is not a system administrator. After `deploy()`, ownership of both contracts belongs
to the supplied jar operator, and only the jar owner can replace its active releaser.
`deployReleaser()` does not update the jar; the new releaser remains inert until the jar owner
adopts it.

## Release execution

`ExchangeReleaser.release(uint256 _nonce, Currency[] assets, address recipient, uint256 maxFee)`
is permissionless. It performs the following operations atomically:

1. The transient-storage reentrancy guard is acquired.
2. `_nonce` must equal `nonce`; the nonce is then incremented.
3. `recipient` must be nonzero and the list must not exceed `maxReleaseLength`.
4. The releaser requests a nominal `threshold` transfer of `resource` from the caller to
   `resourceRecipient`.
5. It reads `FeeController.feeConfig()`, computes `threshold * feeBps / 10_000`, requires the
   amount not to exceed `maxFee`, and requests that transfer when nonzero.
6. `TokenJar.release()` transfers the jar's full balance of each selected asset to `recipient`.
7. It emits `Released` and invokes the specialized `_afterRelease` hook.

A revert anywhere unwinds the nonce increment, resource transfers, jar transfers, and hook. The resource
threshold and protocol fee use separate `transferFrom` calls. `releaseCost()` is a current
quote, not a guarantee; `maxFee` bounds the protocol-fee amount at execution.

## Standing invariants

- **Jar custody is controlled by the current releaser.** `TokenJar.release()` remains
  `onlyReleaser` and `nonReentrant`. The jar owner may rotate the releaser at any time.
- **Selected assets are swept in full.** The caller chooses the asset list, but not amounts.
  `address(0)` represents the native token. Zero balances are skipped.
- **Release configuration changes atomically.** `resource`, `resourceRecipient`, `threshold`,
  and `maxReleaseLength` are mutable only together through `setConfig()`.
- **Every `setConfig()` bumps the nonce.** This includes a no-op same-value update. Never add a
  configuration write that fails to invalidate pending releases.
- **Role changes do not bump the nonce.** `setConfigSetter()` changes authority, not searcher
  terms. The owner may also call `setConfig()` directly.
- **Base releasers cannot send the threshold to the jar or themselves.** Those recipients would
  respectively make a threshold reclaimable during the sweep or strand it. The bridged variant replaces
  this rule by deliberately pinning the recipient to itself.
- **The nonce does not bind all external state.** FeeController state and the resource token's
  own behavior can change without a nonce bump. `maxFee` protects callers from a fee increase;
  token upgrades, pauses, blacklists, and transfer fees remain token risk.
- **FeeController constraints are load-bearing.** A fee may not exceed 1,000 bps, and a nonzero
  fee requires a nonzero recipient. Releasers hold an immutable FeeController reference.
- **Factory salts are sender-scoped.** The effective salt is
  `keccak256(abi.encode(deployer, salt))`; removing this enables cross-chain address squatting
  for the argument-free jar deployment.
- **The reentrancy guard requires Cancun or later.** It uses EIP-1153 transient storage. Both the
  external releaser and jar custody boundary are guarded.

## OP Stack variant

`OptimismBridgedResourceReleaser` has additional invariants:

- `resource` is frozen after construction and must expose a nonzero `l1Token()`.
- `resourceRecipient` is always the releaser itself.
- After the jar sweep, the hook withdraws the releaser's full resource balance through the
  standard bridge at `0x4200000000000000000000000000000000000010`.
- `l1ResourceRecipient` is mutable by the owner or `configSetter` and does not bump the
  release nonce. Already-initiated withdrawals retain the recipient captured at initiation.
- If the token ceases to be bridge-withdrawable, releases revert atomically. Recovery requires
  deploying and adopting a different releaser; changing the base configuration cannot replace
  the frozen resource.

Review the collection, jar sweep, and bridge initiation as one transaction. A revert in the hook
must unwind the earlier resource and asset transfers.

## Hostile-token behavior

Both the resource and jar assets are external contracts. Important cases include:

- a selected jar asset reverting or exhausting gas during `balanceOf` or transfer;
- a nonzero asset address without code, which fails the balance query;
- fee-on-transfer or rebasing tokens, where requested and received amounts can differ;
- callbacks attempting to re-enter either release boundary;
- a resource refusing transfers to the configured resource or fee recipient.

The caller selects the jar assets and sends the resource, so a bad selected asset generally
causes that caller's transaction to revert without blocking releases that omit it. Do not assume
`safeTransferFrom(amount)` proves an exact sender debit or recipient balance increase.

## Intentional behavior that is not a finding

- The jar has an empty payable `receive()`; it is intended to accept native assets passively.
- Nonce increments are `unchecked`; exhausting a `uint256` nonce is not realistic.
- Duplicate asset entries are harmless: the first entry drains the balance and later entries see
  zero.
- An unadopted Factory-deployed releaser can point at any supplied jar address but has no power
  over that jar.
- Factory-deployed contracts are initially configured by the Factory only so it can wire them
  atomically; the Factory transfers ownership before returning.
- Generated and vendored code under `lib/` is outside the repository's authored scope.

## Review posture

Changes under `src/` affect non-upgradeable contracts that can custody protocol fees, so verify
access control, external-call ordering, nonce invalidation, token accounting, and deployment
consequences. Avoid stylistic findings that do not change safety or behavior.

For deployment changes, preserve the pinned compiler profile, CREATE2 salts, initial FeeController
owner, constructor arguments, and canonical deployer assumptions in `script/Deploy.s.sol`.
The published singleton addresses depend on those inputs. For documentation changes, validate
claims against the current interfaces and source rather than legacy `protocol-fees` behavior.
