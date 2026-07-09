// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {IFeeController} from "./IFeeController.sol";

/// @title Factory Interface
/// @notice The interface for deploying partner TokenJar + ExchangeReleaser pairs
interface IFactory {
  /// @notice Thrown when constructing with a zero-address fee controller
  error InvalidFeeController();

  /// @notice Thrown when deploying with a zero-address owner
  error InvalidOwner();

  /// @notice Emitted on every deployment
  /// @dev The releaser's initial configuration is emitted by its own ConfigSet event in the
  /// same transaction
  /// @param jar The deployed TokenJar (the partner's fee destination)
  /// @param releaser The deployed ExchangeReleaser wired to the jar
  /// @param owner The address handed ownership of both contracts
  /// @param configSetter The appointed config setter (address(0) when the role is unset)
  /// @param deployer The deploy() caller (scopes the CREATE2 salt)
  /// @param salt The caller-provided salt
  event JarDeployed(
    address indexed jar,
    address indexed releaser,
    address indexed owner,
    address configSetter,
    address deployer,
    bytes32 salt
  );

  /// @notice Emitted when a standalone releaser is deployed for an existing jar
  /// @dev The releaser's initial configuration is emitted by its own ConfigSet event in the
  /// same transaction. The releaser is inert until the jar owner adopts it via
  /// `jar.setReleaser(releaser)`
  /// @param jar The existing TokenJar the releaser points at
  /// @param releaser The deployed ExchangeReleaser
  /// @param owner The address handed releaser ownership
  /// @param configSetter The appointed config setter (address(0) when the role is unset)
  /// @param deployer The deployReleaser() caller (scopes the CREATE2 salt)
  /// @param salt The caller-provided salt
  event ReleaserDeployed(
    address indexed jar,
    address indexed releaser,
    address indexed owner,
    address configSetter,
    address deployer,
    bytes32 salt
  );

  /// @return Address of the singleton fee controller passed to every deployed releaser
  function FEE_CONTROLLER() external view returns (IFeeController);

  /// @notice Deploys and wires a TokenJar + ExchangeReleaser pair, handing ownership of both
  /// to `owner` and the configSetter role to `configSetter`
  /// @dev Permissionless. The effective CREATE2 salt is keccak256(msg.sender, salt), so a jar
  /// address is only reachable by the same deployer using the same salt — deploy from the same
  /// address on every chain to get the same jar address. Reusing a (deployer, salt) pair on one
  /// chain reverts (CREATE2 collision). The Factory retains no authority afterward.
  /// The two roles are independent: pass `configSetter = address(0)` to leave the role unset
  /// (owner-only config), or `owner = 0xdead` with a live configSetter to freeze the roles and
  /// wiring while keeping terms tunable. `owner = 0xdead` with `configSetter = address(0)`
  /// relinquishes everything atomically at deployment (a trustless-from-birth config; see the
  /// README's burn-configuration tiers). A zero owner reverts — it is far more likely a bug
  /// than intent; use 0xdead to relinquish.
  /// @param revenueToken The initial resource token the releaser charges per release
  /// @param revenueRecipient The initial recipient of the resource tokens
  /// @param threshold The initial amount of resource tokens required per release
  /// @param owner The address receiving ownership of the jar and the releaser; reverts on zero
  /// @param configSetter The address appointed to the releaser's configSetter role; zero leaves
  /// the role unset
  /// @param salt The caller-chosen salt for deterministic addresses
  /// @return jar The deployed TokenJar address
  /// @return releaser The deployed ExchangeReleaser address
  function deploy(
    address revenueToken,
    address revenueRecipient,
    uint256 threshold,
    address owner,
    address configSetter,
    bytes32 salt
  ) external returns (address jar, address releaser);

  /// @notice Deploys a fresh ExchangeReleaser pointed at an existing jar, handing ownership to
  /// `owner` and the configSetter role to `configSetter`
  /// @dev Permissionless — a releaser pointing at a jar is inert until the jar owner adopts it.
  /// The rotation flow is two steps, both by the partner: (1) call this, (2) the jar owner
  /// calls `jar.setReleaser(newReleaser)` (atomic when the jar owner is a Safe). The Factory
  /// deliberately has no power to redirect a jar itself. Once rotation lands, a pending
  /// release against the old releaser reverts atomically inside `jar.release`; searchers
  /// re-simulate on `ReleaserRotated` and the old releaser is harmlessly orphaned.
  /// Role semantics match deploy(): zero configSetter leaves the role unset; zero owner
  /// reverts (use 0xdead to relinquish).
  /// @param jar The existing TokenJar the releaser should release from
  /// @param revenueToken The initial resource token the releaser charges per release
  /// @param revenueRecipient The initial recipient of the resource tokens
  /// @param threshold The initial amount of resource tokens required per release
  /// @param owner The address receiving releaser ownership; reverts on zero
  /// @param configSetter The address appointed to the releaser's configSetter role; zero leaves
  /// the role unset
  /// @param salt The caller-chosen salt (sender-scoped, as in deploy())
  /// @return releaser The deployed ExchangeReleaser address
  function deployReleaser(
    address jar,
    address revenueToken,
    address revenueRecipient,
    uint256 threshold,
    address owner,
    address configSetter,
    bytes32 salt
  ) external returns (address releaser);

  /// @notice Predicts the TokenJar address for a given deployer and salt
  /// @dev The jar takes no constructor args, so its address depends only on this factory, the
  /// deployer, and the salt — the same on every chain this factory is deployed to
  /// @param deployer The address that would call deploy()
  /// @param salt The caller-chosen salt
  /// @return The TokenJar address deploy() would produce
  function predictJar(address deployer, bytes32 salt) external view returns (address);
}
