// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

/// @title Fee Controller Interface
/// @notice The interface for the singleton that holds the protocol fee configuration read by
/// every Releaser on a chain
interface IFeeController {
  /// @notice Thrown when attempting to set the fee above `MAX_FEE_BPS`
  error FeeTooHigh();

  /// @notice Thrown when attempting to set the fee recipient to the zero address
  error InvalidFeeRecipient();

  /// @notice Emitted when the fee bps is updated
  /// @param oldFeeBps The previous fee in basis points
  /// @param newFeeBps The new fee in basis points
  event FeeBpsSet(uint256 oldFeeBps, uint256 newFeeBps);

  /// @notice Emitted when the fee recipient is updated
  /// @param oldRecipient The previous fee recipient
  /// @param newRecipient The new fee recipient
  event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

  /// @return The maximum fee, in basis points, that can be set
  function MAX_FEE_BPS() external view returns (uint256);

  /// @return The current protocol fee, in basis points of a release threshold
  function feeBps() external view returns (uint256);

  /// @return The current protocol fee recipient
  function feeRecipient() external view returns (address);

  /// @notice Returns the full fee configuration in a single call
  /// @dev Releasers read this once when charging the protocol fee so the bps and recipient are
  ///      always taken from the same state
  /// @return bps The current protocol fee, in basis points
  /// @return recipient The current protocol fee recipient
  function feeConfig() external view returns (uint256 bps, address recipient);

  /// @notice Set the protocol fee, in basis points
  /// @dev only callable by `owner`; reverts with `FeeTooHigh` above `MAX_FEE_BPS`, and with
  ///      `InvalidFeeRecipient` when setting a non-zero fee while the recipient is unset
  /// @param newFeeBps The new fee in basis points
  function setFeeBps(uint256 newFeeBps) external;

  /// @notice Set the protocol fee recipient
  /// @dev only callable by `owner`; reverts with `InvalidFeeRecipient` on the zero address
  /// @param newFeeRecipient The new fee recipient
  function setFeeRecipient(address newFeeRecipient) external;
}
