// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Nonce} from "./Nonce.sol";
import {IResourceManager} from "../interfaces/base/IResourceManager.sol";

/// @title ResourceManager
/// @notice A contract that holds the release configuration — the resource token, the resource
/// recipient, the threshold, and the max release length — settable only together, atomically.
/// @dev Inherits Nonce so that every config mutation bumps the release nonce inline, atomically
/// invalidating pending releases whose terms moved underneath them. The invariant to preserve:
/// setConfig always calls _bumpNonce(), unconditionally — including no-op same-value sets.
/// setConfigSetter does not bump; it changes who may set terms, not the terms a searcher priced
/// against.
/// @dev There are deliberately no per-field setters: threshold is denominated in resource, so
/// sequential single-field updates would pass through intermediate configs that are validly
/// releasable at their own nonce (e.g. a WETH threshold briefly expressed in USDC units).
abstract contract ResourceManager is IResourceManager, Owned, Nonce {
  /// @inheritdoc IResourceManager
  ERC20 public resource;

  /// @inheritdoc IResourceManager
  address public resourceRecipient;

  /// @inheritdoc IResourceManager
  uint256 public threshold;

  /// @inheritdoc IResourceManager
  uint256 public maxReleaseLength;

  /// @inheritdoc IResourceManager
  address public configSetter;

  /// @notice Ensures only the config setter or the owner can update the release configuration
  modifier onlyConfigSetterOrOwner() {
    require(msg.sender == configSetter || msg.sender == owner, Unauthorized());
    _;
  }

  /// @dev At construction the configSetter defaults to 0 and maxReleaseLength to 20. The owner
  /// can update the config directly at any time and may appoint a configSetter to delegate that
  /// ability.
  constructor(address _resource, uint256 _threshold, address _owner, address _recipient)
    Owned(_owner)
  {
    _setConfig(_resource, _recipient, _threshold, 20);
  }

  /// @inheritdoc IResourceManager
  function setConfigSetter(address _configSetter) external onlyOwner {
    emit ConfigSetterSet(configSetter, _configSetter);
    configSetter = _configSetter;
  }

  /// @inheritdoc IResourceManager
  function setConfig(
    address _resource,
    address _resourceRecipient,
    uint256 _threshold,
    uint256 _maxReleaseLength
  ) external onlyConfigSetterOrOwner {
    _setConfig(_resource, _resourceRecipient, _threshold, _maxReleaseLength);
    _bumpNonce();
  }

  /// @notice Validates and writes the full release configuration
  /// @dev Shared by the constructor (no bump; the nonce starts fresh) and setConfig (bumps)
  function _setConfig(
    address _resource,
    address _resourceRecipient,
    uint256 _threshold,
    uint256 _maxReleaseLength
  ) private {
    require(_resource != address(0), InvalidResource());
    require(_resourceRecipient != address(0), InvalidResourceRecipient());
    require(_maxReleaseLength != 0, InvalidMaxReleaseLength());
    resource = ERC20(_resource);
    resourceRecipient = _resourceRecipient;
    threshold = _threshold;
    maxReleaseLength = _maxReleaseLength;
    emit ConfigSet(_resource, _resourceRecipient, _threshold, _maxReleaseLength);
  }
}
