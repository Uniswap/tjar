// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IReleaser} from "../../src/interfaces/IReleaser.sol";

/// @title ReentrantJarToken
/// @notice A malicious jar asset that reenters the releaser while it is being swept. Models the
/// one third-party-reachable reentrancy surface: anyone can donate a token to the jar and list it
/// in the caller-supplied `assets[]`, so its `transfer` runs mid-sweep. Used to pin the invariant
/// that reentrancy cannot double-claim the jar and is strictly unprofitable.
contract ReentrantJarToken is MockERC20 {
  IReleaser public releaser;
  uint256 public reentryNonce;
  address public reentryRecipient;
  Currency[] internal reentryAssets;
  bool public armed;

  constructor(string memory _name, string memory _symbol, uint8 _decimals)
    MockERC20(_name, _symbol, _decimals)
  {}

  /// @notice Arms a one-shot reentrant release fired on the next `transfer`
  function arm(IReleaser _releaser, uint256 _nonce, Currency[] calldata _assets, address _recipient)
    external
  {
    releaser = _releaser;
    reentryNonce = _nonce;
    reentryRecipient = _recipient;
    delete reentryAssets;
    for (uint256 i; i < _assets.length; i++) {
      reentryAssets.push(_assets[i]);
    }
    armed = true;
  }

  /// @dev Fires the reentrant release exactly once (disarm first to avoid infinite recursion),
  /// then completes the real transfer so the outer sweep sees a normal ERC20
  function transfer(address destination, uint256 amount) public override returns (bool) {
    if (armed) {
      armed = false;
      releaser.release(reentryNonce, reentryAssets, reentryRecipient);
    }
    return super.transfer(destination, amount);
  }
}
