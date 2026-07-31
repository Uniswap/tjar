// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Currency} from "v4-core/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ResourceManager} from "../base/ResourceManager.sol";
import {ReentrancyGuard} from "../base/ReentrancyGuard.sol";
import {ITokenJar} from "../interfaces/ITokenJar.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {IReleaser} from "../interfaces/IReleaser.sol";

/// @title ExchangeReleaser
/// @notice A contract that releases assets from the TokenJar in exchange for transferring a
/// threshold amount of a resource token, plus an optional protocol fee on top
/// @dev Inherits from ResourceManager for resource transferring functionality and (through it)
/// Nonce for replay protection
/// @dev Note there are some MEV and efficiency considerations around the release length and
/// threshold. If many assets are collected in the token jar, some may never reach a value high
/// enough to be released. Larger release lengths can mitigate this at the cost of higher gas and
/// searching complexity. Sharp price changes relative to the RESOURCE or large deposits into
/// TokenJar can also cause the exchange to be extra profitable for the release caller. Future
/// versions may consider dynamic thresholds or other MEV minimizing auction techniques
/// @custom:security-contact security@uniswap.org
contract ExchangeReleaser is IReleaser, ResourceManager, ReentrancyGuard {
  using SafeTransferLib for ERC20;

  /// @notice Denominator for protocol fee basis points
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @inheritdoc IReleaser
  ITokenJar public immutable TOKEN_JAR;

  /// @inheritdoc IReleaser
  IFeeController public immutable FEE_CONTROLLER;

  /// @notice Creates a new ExchangeReleaser instance
  /// @param _resource The address of the resource token that must be transferred
  /// @param _threshold The minimum amount of resource tokens that must be transferred
  /// @param _tokenJar The address of the TokenJar contract holding the assets
  /// @param _recipient The address that will receive the resource tokens
  /// @param _feeController The address of the singleton protocol fee controller
  constructor(
    address _resource,
    uint256 _threshold,
    address _tokenJar,
    address _recipient,
    address _feeController
  ) ResourceManager(_resource, _threshold, msg.sender, _recipient) {
    require(_tokenJar != address(0), InvalidTokenJar());
    require(_feeController != address(0), InvalidFeeController());
    // The base constructor's _validateConfig runs before TOKEN_JAR is
    // assigned, so it cannot make this check — hence the explicit param comparison here.
    require(_recipient != _tokenJar, InvalidConfig());
    TOKEN_JAR = ITokenJar(payable(_tokenJar));
    FEE_CONTROLLER = IFeeController(_feeController);
  }

  /// @inheritdoc IReleaser
  /// @dev The caller pays `threshold` to the resource recipient, plus a protocol fee of
  /// `threshold * feeBps / BPS_DENOMINATOR` (bounded by `maxFee`) to the protocol fee
  /// recipient. The fee transfer is skipped entirely when the fee rounds to zero
  /// @dev The jar sweep calls out to each listed asset, so `release` is nonReentrant here and
  /// on `TokenJar.release`
  function release(uint256 _nonce, Currency[] calldata assets, address recipient, uint256 maxFee)
    external
    nonReentrant
    handleNonce(_nonce)
  {
    require(recipient != address(0), InvalidRecipient());
    require(assets.length <= maxReleaseLength, TooManyAssets(assets.length, maxReleaseLength));
    resource.safeTransferFrom(msg.sender, resourceRecipient, threshold);

    (uint256 feeBps, address feeRecipient) = FEE_CONTROLLER.feeConfig();
    uint256 fee = (threshold * feeBps) / BPS_DENOMINATOR;
    require(fee <= maxFee, FeeExceedsMax(fee, maxFee));
    if (fee > 0) resource.safeTransferFrom(msg.sender, feeRecipient, fee);

    TOKEN_JAR.release(assets, recipient);
    emit Released(
      _nonce, recipient, address(resource), resourceRecipient, threshold, fee, feeRecipient, assets
    );

    _afterRelease(assets, recipient);
  }

  /// @inheritdoc IReleaser
  function releaseCost() external view returns (uint256 total, uint256 fee) {
    (uint256 feeBps,) = FEE_CONTROLLER.feeConfig();
    fee = (threshold * feeBps) / BPS_DENOMINATOR;
    total = threshold + fee;
  }

  /// @notice Rejects a resource recipient equal to the token jar
  /// @dev Such a config lets a release caller list the resource among `assets` and reclaim the
  /// threshold payment in the same call, draining the jar for the cost of the protocol fee
  /// alone. Guards the setConfig path (TOKEN_JAR is assigned by then). The constructor guards
  /// the deploy path separately, since TOKEN_JAR is still unset when the base constructor runs
  /// this hook.
  function _validateConfig(address, address _resourceRecipient, uint256, uint256)
    internal
    view
    virtual
    override
  {
    require(_resourceRecipient != address(TOKEN_JAR), InvalidConfig());
  }

  /// @notice Internal function to handle any post transfer actions
  /// e.g. bridge calls or notifications
  /// @dev Deliberately kept as a virtual no-op: the extension point for specialized variants
  /// (e.g. a bridged-resource burner) to subclass this concrete contract
  function _afterRelease(Currency[] calldata assets, address recipient) internal virtual {
    // by default do nothing after release
  }
}
