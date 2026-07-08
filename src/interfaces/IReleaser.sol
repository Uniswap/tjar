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

  event Released(uint256 indexed nonce, address indexed recipient, Currency[] assets);

  /// @return Address of the Token Jar contract that will release the assets
  function TOKEN_JAR() external view returns (ITokenJar);

  /// @return Address of the singleton fee controller holding the protocol fee configuration
  function FEE_CONTROLLER() external view returns (IFeeController);

  /// @notice Releases assets to a specified recipient if the resource threshold is met
  /// @param _nonce The nonce for the release, must equal to the contract nonce otherwise revert
  /// @param assets The list of assets (addresses) to release, which may have length limits
  /// Native tokens (Ether) are represented as the zero address
  /// @param recipient The address to receive the released assets, paid out by Token Jar
  function release(uint256 _nonce, Currency[] calldata assets, address recipient) external;
}
