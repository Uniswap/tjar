// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FeeController} from "../src/FeeController.sol";

/// @title HandoffFeeController
/// @notice Per-chain FeeController ceremony: set the fee recipient, then transfer ownership to
/// the chain's governance executor. Run as the current owner (the ops owner from Deploy.s.sol).
/// @dev Unlike Deploy.s.sol, the inputs here are PER-CHAIN — ownership is storage, not
/// initcode, so governance addresses are free to differ (mainnet Timelock vs. each L2's bridge
/// executor) without affecting the FeeController's address.
///
/// !! `transferOwnership` is single-step (solmate Owned): a transfer to a wrong address is
/// unrecoverable. Verify GOVERNANCE is the exact executor address Uniswap governance acts
/// through on THIS chain before broadcasting.
///
/// The window before handoff is low-risk by construction (fee starts at 0 bps, hard-capped,
/// recipient required before a non-zero fee), but running this in the same session as
/// Deploy.s.sol shrinks it to nothing.
///
/// Usage:
///   FEE_CONTROLLER=0x... FEE_RECIPIENT=0x... GOVERNANCE=0x... \
///     forge script script/HandoffFeeController.s.sol --rpc-url <chain> --broadcast
contract HandoffFeeController is Script {
  function run() external {
    FeeController feeController = FeeController(vm.envAddress("FEE_CONTROLLER"));
    address feeRecipient = vm.envAddress("FEE_RECIPIENT");
    address governance = vm.envAddress("GOVERNANCE");

    require(address(feeController).code.length > 0, "FeeController not deployed on this chain");
    require(governance != address(0), "zero governance");

    vm.startBroadcast();

    if (feeController.feeRecipient() != feeRecipient) {
      feeController.setFeeRecipient(feeRecipient);
    }
    feeController.transferOwnership(governance);

    vm.stopBroadcast();

    require(feeController.feeRecipient() == feeRecipient, "recipient not set");
    require(feeController.owner() == governance, "ownership not transferred");

    console2.log("FeeController:", address(feeController));
    console2.log("  feeRecipient:", feeController.feeRecipient());
    console2.log("  owner (governance):", feeController.owner());
  }
}
