// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "../src/base/ReentrancyGuard.sol";

/// @dev Harness exposing the guard directly, so the revert is not wrapped by a transfer library
contract GuardHarness is ReentrancyGuard {
  function outer() external nonReentrant {
    inner();
  }

  function inner() public nonReentrant {}
}

contract ReentrancyGuardTest is Test {
  GuardHarness internal harness = new GuardHarness();

  function test_nonReentrant_blocksNestedCall() public {
    vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
    harness.outer();
  }

  function test_nonReentrant_allowsSequentialCalls() public {
    // the guard clears on each return, so back-to-back top-level calls both succeed
    harness.inner();
    harness.inner();
  }
}
