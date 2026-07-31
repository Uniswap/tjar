// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

/// @title ReentrancyGuard
/// @notice Minimal reentrancy guard backed by EIP-1153 transient storage
/// @dev The lock lives in transient storage: ~100 gas and auto-cleared at the end of the
/// transaction. Requires a cancun (or later) EVM.
abstract contract ReentrancyGuard {
  /// @notice Thrown when a `nonReentrant` function is re-entered
  error Reentrancy();

  bool private transient _entered;

  modifier nonReentrant() {
    require(!_entered, Reentrancy());
    _entered = true;
    _;
    _entered = false;
  }
}
