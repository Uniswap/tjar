// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IResourceManager} from "../interfaces/base/IResourceManager.sol";

/// @title ResourceManager
/// @notice A contract that holds immutable state for the resource token and the resource recipient
/// address. It also maintains logic for managing the threshold of the resource token.
abstract contract ResourceManager is IResourceManager, Owned {
  /// @inheritdoc IResourceManager
  uint256 public threshold;

  /// @inheritdoc IResourceManager
  address public configSetter;

  /// @inheritdoc IResourceManager
  ERC20 public immutable RESOURCE;

  /// @inheritdoc IResourceManager
  address public immutable RESOURCE_RECIPIENT;

  /// @notice Ensures only the config setter or the owner can update the release configuration
  modifier onlyConfigSetterOrOwner() {
    require(msg.sender == configSetter || msg.sender == owner, Unauthorized());
    _;
  }

  /// @dev At construction the configSetter defaults to 0. The owner can update the config
  /// directly at any time and may appoint a configSetter to delegate that ability.
  constructor(address _resource, uint256 _threshold, address _owner, address _recipient)
    Owned(_owner)
  {
    RESOURCE = ERC20(_resource);
    RESOURCE_RECIPIENT = _recipient;
    threshold = _threshold;
  }

  /// @inheritdoc IResourceManager
  function setConfigSetter(address _configSetter) external onlyOwner {
    emit ConfigSetterSet(configSetter, _configSetter);
    configSetter = _configSetter;
  }

  /// @inheritdoc IResourceManager
  function setThreshold(uint256 _threshold) external onlyConfigSetterOrOwner {
    threshold = _threshold;
  }
}
