// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Owned} from "solmate/src/auth/Owned.sol";
import {IFeeController} from "./interfaces/IFeeController.sol";

/// @title FeeController
/// @notice Singleton holding the protocol fee configuration shared by every Releaser on a chain
/// @dev Deployed once per chain at a deterministic address. Releasers hold an immutable reference
///      and read `feeConfig()` when charging the protocol fee on top of a partner's threshold.
///      Owned by the protocol (not partner admins) so the fee cannot be zeroed out by partners,
///      and updates apply to all Releasers without touching partner contracts.
/// @custom:security-contact security@uniswap.org
contract FeeController is Owned, IFeeController {
  /// @inheritdoc IFeeController
  /// @dev Hard ceiling on the protocol fee (10%). The fee is charged on top of the partner's
  ///      threshold; this caps owner mis-configuration. Compile-time constant, not adjustable.
  uint256 public constant MAX_FEE_BPS = 1000;

  /// @inheritdoc IFeeController
  uint256 public feeBps;

  /// @inheritdoc IFeeController
  address public feeRecipient;

  /// @dev Deployed via the canonical CREATE2 deployer, where msg.sender inside the constructor
  ///      is the deployer proxy — hence the explicit `_owner` arg. Pass the SAME owner on every
  ///      chain: the arg is part of the initcode, and chain-invariant initcode is what keeps the
  ///      deployed address identical across chains. `_owner` is the initial operational owner;
  ///      it SHOULD set the fee recipient (the chain-invariant Uniswap Token Jar) and transfer
  ///      ownership to the chain's governance executor during deployment — governance addresses
  ///      differ per chain, which is fine because ownership is storage, not initcode. The fee
  ///      starts at 0 bps and the recipient at address(0); a non-zero fee cannot be enabled
  ///      until a recipient is set.
  constructor(address _owner) Owned(_owner) {
    require(_owner != address(0), InvalidOwner());
  }

  /// @inheritdoc IFeeController
  function feeConfig() external view returns (uint256 bps, address recipient) {
    return (feeBps, feeRecipient);
  }

  /// @inheritdoc IFeeController
  function setFeeBps(uint256 newFeeBps) external onlyOwner {
    require(newFeeBps <= MAX_FEE_BPS, FeeTooHigh());
    // A non-zero fee must have a recipient; prevents charging a fee to address(0).
    require(newFeeBps == 0 || feeRecipient != address(0), InvalidFeeRecipient());
    emit FeeBpsSet(feeBps, newFeeBps);
    feeBps = newFeeBps;
  }

  /// @inheritdoc IFeeController
  function setFeeRecipient(address newFeeRecipient) external onlyOwner {
    require(newFeeRecipient != address(0), InvalidFeeRecipient());
    emit FeeRecipientSet(feeRecipient, newFeeRecipient);
    feeRecipient = newFeeRecipient;
  }
}
