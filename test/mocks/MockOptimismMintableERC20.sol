// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title MockOptimismMintableERC20
/// @notice A MockERC20 that also answers the bridge's `l1Token()` dispatch, standing in for a
/// resource withdrawable through the L2 Standard Bridge
contract MockOptimismMintableERC20 is MockERC20 {
  address public l1Token;

  constructor(string memory _name, string memory _symbol, uint8 _decimals, address _l1Token)
    MockERC20(_name, _symbol, _decimals)
  {
    l1Token = _l1Token;
  }
}
