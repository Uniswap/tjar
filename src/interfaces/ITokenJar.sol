// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Currency} from "v4-core/types/Currency.sol";

/// @title Token Jar Interface
/// @notice The interface for releasing assets from the contract
interface ITokenJar {
  /// @notice Thrown when an unauthorized address attempts to call a restricted function
  error Unauthorized();

  /// @notice Thrown when attempting to set the releaser to the zero address
  error InvalidReleaser();

  /// @notice Emitted when the releaser is set or rotated
  /// @param oldReleaser The previous releaser address
  /// @param newReleaser The new releaser address
  event ReleaserSet(address indexed oldReleaser, address indexed newReleaser);

  /// @return Address of the current IReleaser
  /// @dev The releaser has exclusive access to the `release()` function
  function releaser() external view returns (address);

  /// @notice Set the address of the IReleaser contract
  /// @dev only callable by `owner`
  /// @param _releaser The address of the new releaser contract
  function setReleaser(address _releaser) external;

  /// @notice Release assets to a specified recipient
  /// @dev only callable by `releaser`
  /// @param assets The list of assets to release; native tokens (Ether) are represented as the
  /// zero address
  /// @param recipient The address that receives the released assets
  function release(Currency[] calldata assets, address recipient) external;
}
