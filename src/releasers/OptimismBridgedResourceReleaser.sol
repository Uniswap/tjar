// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Currency} from "v4-core/types/Currency.sol";
import {IL2StandardBridge} from "../interfaces/external/IL2StandardBridge.sol";
import {ExchangeReleaser} from "./ExchangeReleaser.sol";

/// @title OptimismBridgedResourceReleaser
/// @notice A releaser for OP-stack L2s that delivers the collected resource to a recipient on
/// L1 via the standard bridge — for revenue tokens whose meaningful destination lives on L1
/// (a mainnet operations wallet, a treasury, or 0xdead for canonical burns that a local L2
/// transfer could not achieve)
/// @dev **Stage 1: L2 collection and bridge initiation**
/// - a redeemer calls `release()`, paying the resource to this contract (`resourceRecipient`
///   is pinned to `address(this)`)
/// - the TokenJar releases accumulated fee assets to the redeemer's recipient
/// - `_afterRelease()` initiates a bridge withdrawal of this contract's full resource balance
///   to `l1ResourceRecipient`
/// **Stage 2: L1 finalization**
/// - the L2StandardBridge burns the L2 representation held by this contract
/// - a cross-domain message is queued (7-day challenge period on mainnet)
/// - the L1StandardBridge finalizes the withdrawal and delivers the underlying token to
///   `l1ResourceRecipient` on L1
/// @dev The resource must be withdrawable through the L2 Standard Bridge (an
/// OptimismMintableERC20, e.g. bridged USDC.e — NOT native CCTP USDC).
/// @dev Config surface relative to the base: `resource` is frozen after construction and
/// `resourceRecipient` is pinned to `address(this)` (both enforced via _validateConfig — the
/// two-stage flow breaks under either changing); `threshold` and `maxReleaseLength` remain
/// mutable through the usual atomic setConfig; `l1ResourceRecipient` is mutable via its own
/// setter. A partner wanting a different bridged resource deploys a fresh releaser and rotates
/// the jar to it.
/// @custom:security-contact security@uniswap.org
contract OptimismBridgedResourceReleaser is ExchangeReleaser {
  /// @notice Thrown when a config update attempts to change the frozen resource
  error ResourceFrozen();

  /// @notice Thrown when a config update attempts to move resourceRecipient off this contract
  error RecipientNotSelf();

  /// @notice Thrown when setting the L1 resource recipient to the zero address
  error InvalidL1ResourceRecipient();

  /// @notice Emitted when the L1 resource recipient is set, including at construction
  /// @param oldL1ResourceRecipient The previous L1 recipient (address(0) at construction)
  /// @param newL1ResourceRecipient The new L1 recipient
  event L1ResourceRecipientSet(
    address indexed oldL1ResourceRecipient, address indexed newL1ResourceRecipient
  );

  /// @dev OP-stack predeploy address of the L2 Standard Bridge — identical on every OP-stack
  /// chain. Vendored as a constant (with IL2StandardBridge) so the heavyweight optimism
  /// dependency is not needed.
  address internal constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;

  /// @dev The minimum gas limit for the withdrawal transaction on L1;
  /// enough for a simple ERC20 transfer
  uint32 internal constant WITHDRAWAL_MIN_GAS = 100_000;

  /// @notice Where the bridged resource is delivered on L1
  /// @dev `0xdead` is fine for burn-style configs
  address public l1ResourceRecipient;

  /// @notice Creates a new OptimismBridgedResourceReleaser instance
  /// @param _resource The address of the resource token (must be an OptimismMintableERC20
  /// withdrawable through the L2 Standard Bridge)
  /// @param _threshold The initial amount of resource tokens required per release
  /// @param _tokenJar The address of the TokenJar contract holding accumulated fee assets
  /// @param _feeController The address of the singleton protocol fee controller
  /// @param _l1ResourceRecipient The L1 address the bridged resource is delivered to
  /// @dev Sets resourceRecipient to address(this) to enable the two-stage flow:
  ///      Stage 1: collect tokens here (L2) -> Stage 2: bridge to the L1 recipient
  constructor(
    address _resource,
    uint256 _threshold,
    address _tokenJar,
    address _feeController,
    address _l1ResourceRecipient
  ) ExchangeReleaser(_resource, _threshold, _tokenJar, address(this), _feeController) {
    require(_l1ResourceRecipient != address(0), InvalidL1ResourceRecipient());
    l1ResourceRecipient = _l1ResourceRecipient;
    emit L1ResourceRecipientSet(address(0), _l1ResourceRecipient);
  }

  /// @notice Set the L1 address the bridged resource is delivered to
  /// @dev only callable by the `configSetter` or the `owner`; reverts on the zero address
  /// (`0xdead` is fine for burn-style configs). Deliberately does NOT bump the release nonce:
  /// the L1 destination does not change the terms a searcher prices against — the same
  /// rationale as setConfigSetter. Withdrawals already initiated are unaffected; the bridge
  /// delivers them to the recipient captured at initiation.
  /// @param _l1ResourceRecipient The new L1 recipient
  function setL1ResourceRecipient(address _l1ResourceRecipient) external onlyConfigSetterOrOwner {
    require(_l1ResourceRecipient != address(0), InvalidL1ResourceRecipient());
    emit L1ResourceRecipientSet(l1ResourceRecipient, _l1ResourceRecipient);
    l1ResourceRecipient = _l1ResourceRecipient;
  }

  /// @notice Constrains the release configuration to the two-stage-flow invariants
  /// @dev Runs on every config write, including the constructor's initial set (when `resource`
  /// is still unset and may be chosen freely)
  function _validateConfig(address _resource, address _resourceRecipient, uint256, uint256)
    internal
    view
    override
  {
    require(address(resource) == address(0) || _resource == address(resource), ResourceFrozen());
    require(_resourceRecipient == address(this), RecipientNotSelf());
  }

  /// @notice Hook called after assets are released — initiates stage 2 withdrawal to L1
  /// @dev Bridges this contract's FULL resource balance rather than `threshold`: the amount
  /// actually received is what gets delivered (immune to same-transaction threshold reads
  /// racing a config change, and sweeps any dust or donations along with the release payment)
  function _afterRelease(Currency[] calldata, address) internal override {
    // Stage 2: initiate the bridge withdrawal to the L1 recipient. The bridge will:
    // 1. burn the L2 representation held by this contract
    // 2. queue a cross-domain message for L1
    // 3. after the challenge period, deliver the underlying resource to the L1 recipient
    IL2StandardBridge(L2_STANDARD_BRIDGE)
      .withdrawTo(
        address(resource),
        l1ResourceRecipient,
        resource.balanceOf(address(this)),
        WITHDRAWAL_MIN_GAS,
        bytes("")
      );
  }
}
