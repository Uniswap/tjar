// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Currency} from "v4-core/types/Currency.sol";
import {ITokenJar} from "./ITokenJar.sol";
import {IFeeController} from "./IFeeController.sol";
import {IResourceManager} from "./base/IResourceManager.sol";
import {INonce} from "./base/INonce.sol";

interface IReleaser is IResourceManager, INonce {
  /// @notice Thrown when attempting to release too many assets at once
  error TooManyAssets();

  /// @notice Thrown when constructing with a zero-address token jar
  error InvalidTokenJar();

  /// @notice Thrown when constructing with a zero-address fee controller
  error InvalidFeeController();

  /// @notice Thrown when releasing to the zero address, which would irreversibly burn the
  /// released assets (use 0xdead for intentional burns)
  error InvalidRecipient();

  /// @notice Thrown when the live protocol fee exceeds the caller's bound
  /// @param fee The fee computed from the current fee controller config
  /// @param maxFee The caller-supplied maximum
  error FeeExceedsMax(uint256 fee, uint256 maxFee);

  /// @notice Emitted on every release with the caller-requested asset list
  /// @dev `assets` is the requested (superset) list — zero-balance entries transfer nothing.
  /// Reconstruct actual outflows from the assets' own Transfer logs, not from this event
  event Released(uint256 indexed nonce, address indexed recipient, Currency[] assets);

  /// @return Address of the Token Jar contract that will release the assets
  function TOKEN_JAR() external view returns (ITokenJar);

  /// @return Address of the singleton fee controller holding the protocol fee configuration
  function FEE_CONTROLLER() external view returns (IFeeController);

  /// @notice The total resource a caller must hold and approve to release at the current block:
  /// the threshold plus the live protocol fee
  /// @dev The fee is read live from the fee controller and is NOT nonce-protected, so this is a
  /// current-block quote, not a locked price — pass `fee` as the `maxFee` bound to `release`
  /// @return total The full resource debit (threshold + fee)
  /// @return fee The live protocol fee component
  function releaseCost() external view returns (uint256 total, uint256 fee);

  /// @notice Releases assets to a specified recipient if the resource threshold is met
  /// @param _nonce The nonce for the release, must equal to the contract nonce otherwise revert
  /// @param assets The list of assets (addresses) to release, which may have length limits
  /// Native tokens (Ether) are represented as the zero address
  /// @param recipient The address to receive the released assets, paid out by Token Jar
  /// @param maxFee The maximum protocol fee the caller will pay. The fee is the one release
  /// term the nonce does not cover (it is read live from the fee controller), so callers bound
  /// it explicitly; pass type(uint256).max to accept any fee up to the controller's cap
  function release(uint256 _nonce, Currency[] calldata assets, address recipient, uint256 maxFee)
    external;
}
