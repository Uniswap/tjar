// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {IFeeController} from "./IFeeController.sol";

/// @title Factory Interface
/// @notice The interface for deploying partner TokenJar + ExchangeReleaser pairs
interface IFactory {
  /// @notice Thrown when constructing with a zero-address fee controller
  error InvalidFeeController();

  /// @notice Thrown when deploying with a zero-address admin
  error InvalidAdmin();

  /// @notice Emitted on every deployment
  /// @dev The releaser's initial configuration is emitted by its own ConfigSet event in the
  /// same transaction
  /// @param jar The deployed TokenJar (the partner's fee destination)
  /// @param releaser The deployed ExchangeReleaser wired to the jar
  /// @param admin The address handed ownership and the configSetter role
  /// @param deployer The deploy() caller (scopes the CREATE2 salt)
  /// @param salt The caller-provided salt
  event JarDeployed(
    address indexed jar,
    address indexed releaser,
    address indexed admin,
    address deployer,
    bytes32 salt
  );

  /// @return Address of the singleton fee controller passed to every deployed releaser
  function FEE_CONTROLLER() external view returns (IFeeController);

  /// @notice Deploys and wires a TokenJar + ExchangeReleaser pair, handing all authority to
  /// `admin`
  /// @dev Permissionless. The effective CREATE2 salt is keccak256(msg.sender, salt), so a jar
  /// address is only reachable by the same deployer using the same salt — deploy from the same
  /// address on every chain to get the same jar address. Reusing a (deployer, salt) pair on one
  /// chain reverts (CREATE2 collision). The Factory retains no authority afterward.
  /// @param revenueToken The initial resource token the releaser charges per release
  /// @param revenueRecipient The initial recipient of the resource tokens
  /// @param threshold The initial amount of resource tokens required per release
  /// @param admin The address receiving ownership of both contracts and the configSetter role
  /// @param salt The caller-chosen salt for deterministic addresses
  /// @return jar The deployed TokenJar address
  /// @return releaser The deployed ExchangeReleaser address
  function deploy(
    address revenueToken,
    address revenueRecipient,
    uint256 threshold,
    address admin,
    bytes32 salt
  ) external returns (address jar, address releaser);

  /// @notice Predicts the TokenJar address for a given deployer and salt
  /// @dev The jar takes no constructor args, so its address depends only on this factory, the
  /// deployer, and the salt — the same on every chain this factory is deployed to
  /// @param deployer The address that would call deploy()
  /// @param salt The caller-chosen salt
  /// @return The TokenJar address deploy() would produce
  function predictJar(address deployer, bytes32 salt) external view returns (address);
}
