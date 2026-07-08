// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title Resource Manager Interface
/// @notice The interface for managing the resource token and its threshold value
interface IResourceManager {
  /// @notice Thrown when an unauthorized address attempts to call a restricted function
  error Unauthorized();

  /// @notice Emitted when the config setter is updated
  /// @param oldConfigSetter The previous config setter
  /// @param newConfigSetter The new config setter
  event ConfigSetterSet(address indexed oldConfigSetter, address indexed newConfigSetter);

  /// @notice The resource token required by parent IReleaser
  function RESOURCE() external view returns (ERC20);

  /// @notice The recipient of the `RESOURCE` tokens
  function RESOURCE_RECIPIENT() external view returns (address);

  /// @notice The minimum threshold of `RESOURCE` tokens required to perform a release
  function threshold() external view returns (uint256);

  /// @notice The address authorized, alongside the owner, to update the release configuration
  function configSetter() external view returns (address);

  /// @notice Set the address authorized to update the release configuration
  /// @dev only callable by `owner`; setting `address(0)` revokes the role (the owner can
  /// always update the config directly)
  function setConfigSetter(address newConfigSetter) external;

  /// @notice Set the minimum threshold of `RESOURCE` tokens required to perform a release
  /// @dev only callable by the `configSetter` or the `owner`
  /// the caller should take explicit care when updating the threshold
  /// * lowering the threshold may create instantaneous value leakage
  /// * front-running a release with an increased threshold may cause economic loss
  /// to the releaser/searcher
  function setThreshold(uint256 newThreshold) external;
}
