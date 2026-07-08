// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {TokenJar} from "./TokenJar.sol";
import {ExchangeReleaser} from "./releasers/ExchangeReleaser.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {IFeeController} from "./interfaces/IFeeController.sol";

/// @title Factory
/// @notice Deploys partner TokenJar + ExchangeReleaser pairs via CREATE2 and hands all
/// authority to the partner's admin
/// @dev Deployed at the same address on every chain (canonical CREATE2 deployer, pinned
/// toolchain), which — together with the arg-less TokenJar — gives partners the same jar
/// address across chains. deploy() is permissionless; salts are scoped to msg.sender so no
/// one can squat another deployer's predicted addresses. The Factory keeps no registry and
/// retains no owner, releaser, withdrawal, or config authority over deployed contracts.
/// @custom:security-contact security@uniswap.org
contract Factory is IFactory {
  /// @inheritdoc IFactory
  IFeeController public immutable FEE_CONTROLLER;

  /// @dev The fee controller singleton lives at the same address on every chain, keeping this
  /// constructor arg — and therefore the Factory's own initcode and address — chain-invariant
  constructor(address _feeController) {
    require(_feeController != address(0), InvalidFeeController());
    FEE_CONTROLLER = IFeeController(_feeController);
  }

  /// @inheritdoc IFactory
  function deploy(
    address revenueToken,
    address revenueRecipient,
    uint256 threshold,
    address admin,
    bytes32 salt
  ) external returns (address jar, address releaser) {
    require(admin != address(0), InvalidAdmin());
    bytes32 effectiveSalt = _effectiveSalt(msg.sender, salt);

    // the jar first: it takes no constructor args (cross-chain address parity) and the
    // releaser needs its address
    TokenJar tokenJar = new TokenJar{salt: effectiveSalt}();
    ExchangeReleaser exchangeReleaser = new ExchangeReleaser{salt: effectiveSalt}(
      revenueToken, threshold, address(tokenJar), revenueRecipient, address(FEE_CONTROLLER)
    );

    tokenJar.setReleaser(address(exchangeReleaser));
    tokenJar.transferOwnership(admin);

    exchangeReleaser.setConfigSetter(admin);
    exchangeReleaser.transferOwnership(admin);

    jar = address(tokenJar);
    releaser = address(exchangeReleaser);
    emit JarDeployed(jar, releaser, admin, msg.sender, salt);
  }

  /// @inheritdoc IFactory
  function predictJar(address deployer, bytes32 salt) external view returns (address) {
    return address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff),
              address(this),
              _effectiveSalt(deployer, salt),
              keccak256(type(TokenJar).creationCode)
            )
          )
        )
      )
    );
  }

  /// @notice Scopes a caller-provided salt to the deployer
  /// @dev Mandatory with permissionless deploy(): the arg-less jar's address depends only on
  /// the salt, so an unscoped salt would let a griefer front-run a partner's deploy on another
  /// chain and squat their predicted jar address with a different admin
  function _effectiveSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encode(deployer, salt));
  }
}
