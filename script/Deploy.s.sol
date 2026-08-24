// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FeeController} from "../src/FeeController.sol";
import {Factory} from "../src/Factory.sol";

/// @title Deploy
/// @notice Deterministic per-chain deployment of the TJAR singletons: FeeController, then
/// Factory. Idempotent — safe to re-run on a chain where either is already deployed.
/// @dev Both contracts deploy through the canonical CREATE2 deployer
/// (0x4e59b44847b379578588920cA78FbF26c0B4956C; forge routes salted creates through it when
/// broadcasting), so the addresses depend only on the salt and the initcode. To land at the
/// SAME addresses on every chain, three things are frozen forever:
///   1. the salts — FEE_CONTROLLER_SALT and FACTORY_SALT below;
///   2. the compiler profile (solc version + optimizer settings in foundry.toml) — initcode
///      must stay byte-identical, so the profile used for the first deployment is pinned for
///      all future chains;
///   3. OPS_OWNER — it is a constructor arg, i.e. part of the FeeController initcode. Use an
///      address controlled on every chain (an EOA, or a deterministically deployed Safe).
/// The Factory's constructor arg is the predicted FeeController address, which is itself
/// chain-invariant, keeping the Factory's initcode — and address — chain-invariant too.
///
/// Usage:
///   OPS_OWNER=0x... forge script script/Deploy.s.sol --rpc-url <chain> --broadcast --verify
///
/// After deploying, run HandoffFeeController.s.sol per chain (see script/README.md).
contract Deploy is Script {
  bytes32 public constant FEE_CONTROLLER_SALT =
    0xf8a661d537b79e983ae29ed681edd987f2febd934690d0abcda900e57b28a78e;
  bytes32 public constant FACTORY_SALT =
    0x2179a60856e37dfeaaca0ab043b931fe224b27b69b06e3b62a0dfc02eb0b97aa;

  function run() external returns (address feeController, address factory) {
    address opsOwner = vm.envAddress("OPS_OWNER");

    feeController = vm.computeCreate2Address(
      FEE_CONTROLLER_SALT,
      keccak256(abi.encodePacked(type(FeeController).creationCode, abi.encode(opsOwner)))
    );
    factory = vm.computeCreate2Address(
      FACTORY_SALT,
      keccak256(abi.encodePacked(type(Factory).creationCode, abi.encode(feeController)))
    );

    vm.startBroadcast();

    if (feeController.code.length == 0) {
      FeeController deployedFeeController = new FeeController{salt: FEE_CONTROLLER_SALT}(opsOwner);
      require(address(deployedFeeController) == feeController, "FeeController address mismatch");
      // the regression this guards: through the CREATE2 proxy, msg.sender in the constructor
      // is the proxy — ownership must come from the arg
      require(deployedFeeController.owner() == opsOwner, "FeeController owner mismatch");
      console2.log("FeeController deployed:", feeController);
    } else {
      console2.log("FeeController already deployed:", feeController);
    }

    if (factory.code.length == 0) {
      // the constructor arg is the predicted (chain-invariant) FeeController address
      Factory deployedFactory = new Factory{salt: FACTORY_SALT}(feeController);
      require(address(deployedFactory) == factory, "Factory address mismatch");
      console2.log("Factory deployed:", factory);
    } else {
      console2.log("Factory already deployed:", factory);
    }

    vm.stopBroadcast();

    // sanity: the factory points at the singleton regardless of which branch ran
    require(address(Factory(factory).FEE_CONTROLLER()) == feeController, "Factory wiring mismatch");
  }
}
