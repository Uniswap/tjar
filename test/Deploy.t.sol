// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {FeeController} from "../src/FeeController.sol";
import {Factory} from "../src/Factory.sol";
import {ExchangeReleaser} from "../src/releasers/ExchangeReleaser.sol";

/// @dev Minimal stand-in for the canonical CREATE2 deployer: a contract creator that is not
/// the intended owner. Used to test the deployment path's ownership semantics locally.
contract Create2Forwarder {
  function deployWith(bytes32 salt, bytes memory initcode) external returns (address addr) {
    assembly {
      addr := create2(0, add(initcode, 0x20), mload(initcode), salt)
    }
    require(addr != address(0), "create2 failed");
  }
}

contract DeployTest is Test {
  bytes32 internal salt;
  address internal opsOwner = makeAddr("OPS_OWNER");
  address internal governance = makeAddr("GOVERNANCE");
  address internal feeRecipient = makeAddr("FEE_RECIPIENT");

  function setUp() public {
    salt = new Deploy().TJAR_SALT();
  }

  /// @dev the deployment-path regression, runnable without a fork: when the contract creator
  /// is a proxy (not the operator), ownership must come from the constructor arg — an
  /// Owned(msg.sender) constructor would hand ownership to the forwarder and brick the config
  function test_ownerComesFromArg_notFromCreator() public {
    Create2Forwarder forwarder = new Create2Forwarder();
    address deployed = forwarder.deployWith(
      salt, abi.encodePacked(type(FeeController).creationCode, abi.encode(opsOwner))
    );

    assertEq(FeeController(deployed).owner(), opsOwner);
    assertTrue(FeeController(deployed).owner() != address(forwarder));
  }

  /// @dev the full deployment path against the REAL canonical CREATE2 deployer on a mainnet
  /// fork: address prediction, ownership, wiring, handoff ceremony, and a partner
  /// deploy + release smoke test. Skipped when MAINNET_RPC_URL is unset (runs in CI).
  function test_fork_deployThroughCanonicalProxy() public {
    string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
    vm.skip(bytes(rpcUrl).length == 0, "MAINNET_RPC_URL unset");
    vm.createSelectFork(rpcUrl);

    // --- FeeController through the real proxy ---
    bytes memory feeControllerInitcode =
      abi.encodePacked(type(FeeController).creationCode, abi.encode(opsOwner));
    address predictedFeeController =
      vm.computeCreate2Address(salt, keccak256(feeControllerInitcode));

    (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, feeControllerInitcode));
    assertTrue(ok, "FeeController deploy through proxy failed");
    assertGt(predictedFeeController.code.length, 0, "predicted FeeController address empty");
    // the msg.sender regression, on the real deployment path
    assertEq(FeeController(predictedFeeController).owner(), opsOwner);

    // --- Factory through the real proxy, wired to the predicted singleton ---
    bytes memory factoryInitcode =
      abi.encodePacked(type(Factory).creationCode, abi.encode(predictedFeeController));
    address predictedFactory = vm.computeCreate2Address(salt, keccak256(factoryInitcode));

    (ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, factoryInitcode));
    assertTrue(ok, "Factory deploy through proxy failed");
    assertEq(address(Factory(predictedFactory).FEE_CONTROLLER()), predictedFeeController);

    // --- handoff ceremony (HandoffFeeController.s.sol flow) ---
    vm.startPrank(opsOwner);
    FeeController(predictedFeeController).setFeeRecipient(feeRecipient);
    FeeController(predictedFeeController).transferOwnership(governance);
    vm.stopPrank();
    assertEq(FeeController(predictedFeeController).feeRecipient(), feeRecipient);
    assertEq(FeeController(predictedFeeController).owner(), governance);

    // --- partner deploy + release smoke on the fork ---
    MockERC20 resource = new MockERC20("Resource", "RSC", 18);
    MockERC20 assetToken = new MockERC20("Asset", "AST", 18);
    address partner = makeAddr("PARTNER");
    address searcher = makeAddr("SEARCHER");
    uint256 threshold = 100e18;

    (address jar, address releaser) = Factory(predictedFactory)
      .deploy(address(resource), partner, threshold, partner, address(0), keccak256("fork-partner"));

    assetToken.mint(jar, 1000e18);
    resource.mint(searcher, threshold);

    Currency[] memory assets = new Currency[](1);
    assets[0] = Currency.wrap(address(assetToken));

    vm.startPrank(searcher);
    resource.approve(releaser, type(uint256).max);
    ExchangeReleaser(releaser).release(0, assets, searcher);
    vm.stopPrank();

    assertEq(assetToken.balanceOf(searcher), 1000e18);
    assertEq(resource.balanceOf(partner), threshold);
  }
}
