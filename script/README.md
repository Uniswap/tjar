# TJAR deployment

Two scripts, run in order per chain. Both are idempotent and safe to re-run.

## 0. Invariants that must never change

Deterministic cross-chain addresses require byte-identical **initcode** on every chain,
forever. Three things are therefore frozen after the first deployment anywhere:

| Frozen | Where | Why |
|---|---|---|
| `FEE_CONTROLLER_SALT`, `FACTORY_SALT` | constants in `Deploy.s.sol` | distinct mined salts used by the production deployments; each is part of its contract's CREATE2 address derivation |
| Compiler profile | `foundry.toml` (`solc_version`, `optimizer`, `optimizer_runs`, `evm_version`) | different settings → different initcode → different addresses on later chains |
| `INITIAL_OPS_OWNER` | constant in `Deploy.s.sol` | it is a FeeController constructor arg, i.e. part of its initcode |

`INITIAL_OPS_OWNER` is pinned to the address used by the production deployments,
`0x2179a60856E37dfeAacA0ab043B931fE224b27B6`. It is the *initial operational owner
only* — governance receives ownership in step 2, and governance addresses are free to
differ per chain (ownership is storage, not initcode).

## 1. Deploy the singletons

```bash
forge script script/Deploy.s.sol --rpc-url <chain> --broadcast --verify
```

Deploys through the canonical CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`), FeeController first, then the Factory
wired to it, using each contract's mined salt. Prints the (chain-invariant) addresses and
reverts if anything lands off prediction. Re-running on a chain where the contracts exist
is a no-op.

Order matters: factory-deployed releasers call `feeConfig()` on every release, so the
FeeController must exist before any partner deployment — the script enforces this by
deploying it first in the same run.

> **New chains: deploy before wiring.** Before any fee source is pointed at a jar
> address on a chain, verify the Factory's code sits at its canonical address there and
> deploy the jar itself. Funds sent to a predicted-but-undeployed address are stranded
> if the Factory can never land on that chain, and a contract-account deployer another
> party can recreate exposes them to theft (see the prefunding caution in the main
> README). Use an EOA deployer for any salt reused across chains.

## 2. Hand off to governance (per chain)

```bash
FEE_CONTROLLER=0x... FEE_RECIPIENT=0x... GOVERNANCE=0x... \
  forge script script/HandoffFeeController.s.sol --rpc-url <chain> --broadcast
```

Run as `INITIAL_OPS_OWNER`. Sets the fee recipient (the Uniswap Token Jar — itself
chain-invariant) and transfers ownership to this chain's governance executor.

> **Verify `GOVERNANCE` before broadcasting.** It differs per chain — the Timelock on
> mainnet, the bridge executor Uniswap governance acts through on each L2 — and
> `transferOwnership` is single-step: a transfer to the wrong address is unrecoverable.

The window between deploy and handoff is low-risk by construction (fee starts at 0 bps,
hard-capped at `MAX_FEE_BPS`, recipient required before a non-zero fee), but running
both scripts in the same session shrinks it to nothing.

## Testing the deployment path

`test/Deploy.t.sol` covers the path normal tests can't see:

- `test_ownerComesFromArg_notFromCreator` (always runs) — deploying through a contract
  creator must hand ownership to the constructor arg, not the creator. This is the
  regression that would have bricked the FeeController via the CREATE2 proxy.
- `test_fork_deployThroughCanonicalProxy` (needs `MAINNET_RPC_URL`; skipped otherwise)
  — the full ceremony against the *real* proxy on a mainnet fork: address prediction,
  ownership, wiring, handoff, and a partner deploy + release smoke test.

## Ethereum L1 after the Amsterdam upgrade

Amsterdam (Glamsterdam) adds state gas for deployed code (EIP-8037, 1,530 gas per byte).
A large contract then needs more than 2^24 (16,777,216) gas to deploy. For example, a v4
PoolManager deployment (24,009 bytes of code) used 37,435,950 gas on Sepolia.

The local `forge script` simulation uses the gas rules of the configured `evm_version`,
which is older than Amsterdam. It sets a gas limit that is too low, and the deployment
transaction reverts on chain. For the PoolManager example, the simulation set a gas
limit of 7,256,884.

On a chain that runs Amsterdam, add `--skip-simulation` to the `forge script` commands
in this file. forge then gets the gas limit of each transaction from `eth_estimateGas`
on the RPC node, multiplied by `--gas-estimate-multiplier` (default 130). Fund the
deployer for the higher gas cost. The PoolManager example used 37,435,950 gas with
Amsterdam rules and 5,253,854 gas with Osaka rules. Do not use `--gas-limit` for this.
In `forge script` it sets the block gas limit of the local simulation, not the gas limit
of the transaction.
