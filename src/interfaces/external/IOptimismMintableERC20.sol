// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOptimismMintableERC20 {
  /// @notice Address of the corresponding token on the remote (L1) chain. Legacy getter — the
  ///         L2StandardBridge's `withdrawTo` dispatches on it, so a token withdrawable through
  ///         the standard bridge must implement it.
  function l1Token() external view returns (address);
}
