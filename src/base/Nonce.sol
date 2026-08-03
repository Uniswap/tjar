// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {INonce} from "../interfaces/base/INonce.sol";

/// @title Nonce
/// @notice An abstract contract that provides nonce validation for transaction ordering protection
/// @dev Implements sequential nonce validation to prevent front-running and ensure searchers
///      can guarantee their transaction order when releasing available tokens
abstract contract Nonce is INonce {
  /// @inheritdoc INonce
  uint256 public nonce;

  /// @notice Validates and increments the nonce for transaction ordering protection
  /// @dev Ensures releases are processed in the expected order, preventing front-running when
  ///      searchers submit a release to claim available tokens. The nonce guarantees that if a
  ///      searcher simulates a release at a specific nonce, they can execute it without another
  ///      transaction landing first. The nonce advances both on every release and on every config
  ///      change (via _bumpNonce), so the terms a searcher simulated against cannot move underneath
  ///      a pending release: if they do, the nonce no longer matches and the release reverts.
  ///      Reverts with InvalidNonce if the provided nonce doesn't match the current contract nonce.
  /// @param _nonce The expected current nonce value
  modifier handleNonce(uint256 _nonce) {
    require(_nonce == nonce, InvalidNonce());
    _bumpNonce();
    _;
  }

  /// @notice Increments the nonce without validating an expected value
  /// @dev Used by config setters to invalidate any pending release when the release terms change.
  ///      Unlike handleNonce, this takes no expected-nonce argument: callers such as the admin or
  ///      configSetter are not racing for a specific nonce, they just need to advance it.
  function _bumpNonce() internal {
    unchecked {
      ++nonce;
    }
  }
}
