// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title Resource Manager Interface
/// @notice The interface for managing the release configuration: the resource token, the
/// resource recipient, the threshold, and the max release length
interface IResourceManager {
  /// @notice Thrown when an unauthorized address attempts to call a restricted function
  error Unauthorized();

  /// @notice Thrown when setting the resource to the zero address
  error InvalidResource();

  /// @notice Thrown when setting the resource recipient to the zero address
  error InvalidResourceRecipient();

  /// @notice Thrown when setting the max release length to zero
  error InvalidMaxReleaseLength();

  /// @notice Emitted when the config setter is updated
  /// @param oldConfigSetter The previous config setter
  /// @param newConfigSetter The new config setter
  event ConfigSetterSet(address indexed oldConfigSetter, address indexed newConfigSetter);

  /// @notice Emitted whenever the release configuration is set, carrying the complete new config
  /// @dev carries no nonce field; searchers should re-simulate on any config event and read
  /// `nonce()` fresh
  /// @param resource The resource token
  /// @param resourceRecipient The recipient of the resource tokens
  /// @param threshold The amount of resource tokens required per release
  /// @param maxReleaseLength The maximum number of assets per release
  event ConfigSet(
    address indexed resource,
    address indexed resourceRecipient,
    uint256 threshold,
    uint256 maxReleaseLength
  );

  /// @notice The resource token required by parent IReleaser
  function resource() external view returns (ERC20);

  /// @notice The recipient of the `resource` tokens
  function resourceRecipient() external view returns (address);

  /// @notice The minimum threshold of `resource` tokens required to perform a release
  function threshold() external view returns (uint256);

  /// @notice The maximum number of assets that can be released in a single call
  function maxReleaseLength() external view returns (uint256);

  /// @notice The address authorized, alongside the owner, to update the release configuration
  function configSetter() external view returns (address);

  /// @notice Set the address authorized to update the release configuration
  /// @dev only callable by `owner`; setting `address(0)` revokes the role (the owner can
  /// always update the config directly). Does NOT bump the release nonce: it changes who may
  /// set terms, not the terms a searcher priced against.
  function setConfigSetter(address newConfigSetter) external;

  /// @notice Set the full release configuration, atomically
  /// @dev only callable by the `configSetter` or the `owner`
  /// Bumps the release nonce — unconditionally, including same-value sets — atomically
  /// invalidating any pending release priced against the old terms.
  /// There are deliberately no per-field setters: threshold is denominated in resource, so
  /// partial updates would pass through releasable intermediate configs.
  /// the caller should take explicit care when updating the config
  /// * lowering the threshold (relative to the resource's value) may create instantaneous
  /// value leakage
  /// * a config change invalidates in-flight releases (they revert on nonce), which is a
  /// gas grief on searchers, identical in kind to a Releaser rotation
  /// @param newResource The resource token; reverts with InvalidResource on zero
  /// @param newResourceRecipient The recipient of the resource tokens; reverts with
  /// InvalidResourceRecipient on zero (0xdead is fine for burn-style configs)
  /// @param newThreshold The amount of resource tokens required per release
  /// @param newMaxReleaseLength The maximum number of assets per release; reverts with
  /// InvalidMaxReleaseLength on zero
  function setConfig(
    address newResource,
    address newResourceRecipient,
    uint256 newThreshold,
    uint256 newMaxReleaseLength
  ) external;
}
