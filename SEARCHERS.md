# TJAR Searcher Guide

This guide explains how searchers discover TJAR token jars, evaluate release opportunities,
and submit releases. It covers asset discovery, pricing, nonce and fee handling, releaser
rotation, failure modes, and deployment addresses.

## Overview

A `TokenJar` receives protocol-fee assets through standard native-token or ERC-20 transfers.
The jar does not index these assets or emit an event when it receives them. Each jar has one
authorized `releaser`, which is the only address permitted to transfer assets out of the jar.

An `ExchangeReleaser` allows a searcher to pay a `threshold` configured by the jar operator in
exchange for the jar's full balance of a specified set of assets. The searcher also pays the
current protocol fee, if one is configured. Released assets are sent to a recipient selected by
the searcher.

The mechanism does not use an auction, bidding process, or oracle. The jar operator updates the
`threshold`, while the `FeeController` supplies the protocol fee at execution time. A release
opportunity exists when the value of the selected assets exceeds the total cost of the release.

This guide describes releasers that use the interface and pricing behavior of the included
`ExchangeReleaser`. The compatible `OptimismBridgedResourceReleaser` additionally bridges the
resource token from L2 to L1 after a release. Because a jar owner may adopt a custom releaser,
inspect unrecognized releaser contracts before relying on the behavior described here.

## Evaluating a release

A release is profitable when:

```
value(selected assets) > threshold + protocol fee + execution costs
```

The `threshold` and protocol fee are denominated in the `resource` token. Released assets are
transferred in their existing form; their valuation and conversion occur outside the protocol.

The release threshold is independent of the jar's balances. As a result:

- Assets can accumulate without changing the threshold.
- The same threshold applies regardless of the number of assets selected, subject to
  `maxReleaseLength`.

Selecting an additional asset does not reduce the release price. Searchers can therefore
evaluate all known jar assets and include those whose recoverable value exceeds their additional
execution cost and risk.

## Submitting a release

Call `release` on the jar's current releaser:

```solidity
releaser.release(
    uint256    nonce,      // Must equal releaser.nonce() at execution time
    Currency[] assets,     // Asset addresses; address(0) represents the native token
    address    recipient,  // Receives the released assets and must not be address(0)
    uint256    maxFee      // Maximum acceptable protocol fee
);
```

`Currency` is a user-defined value type backed by `address`. It is represented as `address` in
the ABI, so clients can encode this argument as `address[]`.

Before submitting the transaction, approve the releaser to spend at least `threshold + fee` of
the `resource` token. The releaser collects the threshold and fee with separate `transferFrom`
calls, but a single allowance covering their sum is sufficient.

`releaseCost()` returns `(total, fee)`, where `total` is the complete resource-token payment and
`fee` is its protocol-fee component at the current block.

## Discovering jar assets

A jar does not expose an enumerable list of the assets it holds. Searchers must construct an
asset list before querying the jar's balance of each asset. Common discovery sources include:

1. **Previous `Released` events.** The `assets` array records the assets selected in earlier
   releases. This provides a useful starting point but does not identify assets that have never
   been included in a release.
2. **Indexed transfers.** Index ERC-20 `Transfer` events with the jar as the recipient and use
   call traces to identify native-token transfers. This captures assets independently of prior
   release activity.

After constructing the asset list, read the current release configuration:

```bash
cast call $RELEASER "nonce()(uint256)"                 --rpc-url $RPC
cast call $RELEASER "releaseCost()(uint256,uint256)"   --rpc-url $RPC
cast call $RELEASER "resource()(address)"              --rpc-url $RPC
cast call $RELEASER "maxReleaseLength()(uint256)"      --rpc-url $RPC
cast call $JAR      "releaser()(address)"              --rpc-url $RPC
```

Confirm that `TokenJar.releaser()` still matches the releaser being evaluated. A rotated
releaser continues to return its configuration through view functions but cannot execute a
release.

## Nonce behavior

The nonce protects the release configuration controlled by the jar operator. If a searcher
simulates a transaction at nonce N and the releaser remains at nonce N when the transaction
executes, the `resource`, `resourceRecipient`, `threshold`, and `maxReleaseLength` configuration
has not changed. The nonce does not protect the protocol fee or the behavior of the resource
token.

A successful release advances the nonce. A call to `setConfig` also advances it, including when
the supplied configuration matches the existing configuration. A transaction submitted with an
outdated nonce reverts with `InvalidNonce`.

This behavior has two operational implications:

- The nonce is not a release counter. Use `Released` events to count completed releases.
- Competing transactions using the same nonce cannot both execute successfully. A transaction
  that executes after the nonce has advanced reverts without transferring the release payment.

The protocol fee is maintained by the chain-wide `FeeController` and is read when the release
executes. It may therefore change after simulation without advancing the releaser nonce. Use
`maxFee` to bound this change. Setting `maxFee` to `type(uint256).max` accepts any fee up to the
controller's hard limit of 1,000 basis points.

## Failure modes

| Revert | Source | Cause and response |
| --- | --- | --- |
| `InvalidNonce()` | releaser | Another release executed or the jar operator updated the configuration. Read `nonce()` again and re-simulate. |
| `Unauthorized()` | jar | The called releaser is not the jar's current releaser. Read `TokenJar.releaser()` and evaluate the active contract. |
| `TooManyAssets(count, max)` | releaser | The asset list exceeds `maxReleaseLength`, which defaults to 20. Reduce the list to the current limit. |
| `FeeExceedsMax(fee, maxFee)` | releaser | The protocol fee exceeds the supplied bound. Re-evaluate the release before increasing `maxFee`. |
| `InvalidRecipient()` | releaser | The recipient is the zero address. Supply a nonzero recipient. |
| `TRANSFER_FROM_FAILED` | releaser | A resource-token `transferFrom` failed. Check balance, allowance, token pause or blacklist rules, and recipient restrictions. |
| Token-specific revert | jar | A selected asset reverted during `balanceOf` or `transfer`. Identify and remove or separately handle the incompatible asset. |

## Operational considerations

### Native token representation

The native token is represented by `address(0)` in the asset list, and native-token transfers do
not emit ERC-20 `Transfer` events. Account for native-token balances and transfers separately
when indexing or reconciling releases. The native token is POL on Polygon and ETH on the other
deployments listed below.

### Asset address validation

Including a nonzero address without contract code causes the entire release to revert. The jar
queries `balanceOfSelf()` for every selected asset, and this query fails for a nonzero address
without code. Validate asset addresses before submitting a release.

An asset with a zero jar balance does not cause a revert or transfer. It still increases calldata
and execution cost, so asset lists should be kept current when practical.

### Releaser rotation

A jar owner may change the jar's releaser at any time. A previous releaser continues to expose
its configuration but reverts with `Unauthorized()` while inactive. Track `ReleaserSet` events
and confirm the current value of `TokenJar.releaser()` before submitting a transaction. A
previous releaser can become active again if the jar owner readopts it.

### Fee-on-transfer resource tokens

For a fee-on-transfer resource token, the releaser requests nominal transfers for the `threshold`
and protocol fee. Token-specific transfer behavior determines the searcher's exact balance change
and the amount each recipient receives. With `OptimismBridgedResourceReleaser`, the resource token
is first transferred to the releaser, and only the received balance is bridged to L1.

### Reentrancy

The jar and releaser use transient-storage reentrancy guards. Token callbacks cannot re-enter
`release` while a release is in progress.

## Discovering jars and releasers

The `Factory` is permissionless and does not maintain a registry of deployed jars. Use contract
events to discover deployments and changes:

| Event | Contract | Meaning |
| --- | --- | --- |
| `JarDeployed` | Factory | A new jar and its initial releaser were deployed and connected. |
| `ReleaserDeployed` | Factory | A standalone releaser was deployed for the supplied jar address. The releaser remains inactive until that jar adopts it. |
| `ReleaserSet` | jar | The jar changed its active releaser. The most recent value identifies the active releaser. |

A `ReleaserDeployed` event does not establish that the supplied jar exists, is compatible, or has
adopted the releaser. A releaser can also be deployed without the Factory. In both cases, the
jar's `ReleaserSet` events and current `releaser()` value determine whether the contract is active.

`ReleaserSet` establishes adoption but not interface compatibility. Inspect unrecognized
contracts before assuming they implement `releaseCost()` or use the fee, pricing, and recipient
behavior described in this guide.

The Factory and `FeeController` use the same addresses on each supported chain. A jar operator
who deploys from the same account with the same caller-provided salt also receives the same jar
address across these chains. Index jars and releasers by `(chain_id, address)` to distinguish
chain-specific state.

## Deployments

| Chain | Factory | FeeController |
| --- | --- | --- |
| Ethereum (1) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://etherscan.io/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://etherscan.io/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |
| Optimism (10) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://optimistic.etherscan.io/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://optimistic.etherscan.io/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |
| Polygon (137) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://polygonscan.com/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://polygonscan.com/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |
| Base (8453) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://basescan.org/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://basescan.org/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |
| Arbitrum (42161) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://arbiscan.io/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://arbiscan.io/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |
| Robinhood Chain (4663) | [`0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee`](https://robinhoodchain.blockscout.com/address/0xfAc70EEEE259F2140CBbB8e3157b75A52ce39fee) | [`0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8`](https://robinhoodchain.blockscout.com/address/0xfEeC0FEE579Be52a5409cd75a42bCc9E6b149EF8) |

## Support

Report security issues to security@uniswap.org. For other questions, open an issue in this
repository.
