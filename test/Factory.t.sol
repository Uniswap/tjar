// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ProtocolFeesTestBase} from "./utils/ProtocolFeesTestBase.sol";
import {Factory} from "../src/Factory.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";
import {TokenJar} from "../src/TokenJar.sol";
import {ExchangeReleaser} from "../src/releasers/ExchangeReleaser.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";

contract FactoryTest is ProtocolFeesTestBase {
  Factory public factory;
  address public admin = makeAddr("ADMIN");
  address public partnerRecipient = makeAddr("PARTNER_RECIPIENT");
  bytes32 public constant SALT = keccak256("partner-1");
  uint256 public constant THRESHOLD = 100e18;

  function setUp() public override {
    super.setUp();
    factory = new Factory(address(feeController));
  }

  function _deploy(address caller) internal returns (address jar, address releaser) {
    vm.prank(caller);
    return factory.deploy(address(resource), partnerRecipient, THRESHOLD, admin, SALT);
  }

  function test_deploy_wiresEverything() public {
    (address jar, address releaser) = _deploy(bob);

    TokenJar j = TokenJar(payable(jar));
    ExchangeReleaser r = ExchangeReleaser(releaser);

    // jar wiring
    assertEq(j.releaser(), releaser);
    assertEq(j.owner(), admin);

    // releaser wiring
    assertEq(address(r.TOKEN_JAR()), jar);
    assertEq(address(r.FEE_CONTROLLER()), address(feeController));
    assertEq(address(r.resource()), address(resource));
    assertEq(r.resourceRecipient(), partnerRecipient);
    assertEq(r.threshold(), THRESHOLD);
    assertEq(r.maxReleaseLength(), 20);
    assertEq(r.owner(), admin);
    assertEq(r.configSetter(), admin);
    assertEq(r.nonce(), 0);
  }

  function test_deploy_emitsJarDeployed() public {
    address predictedJar = factory.predictJar(bob, SALT);
    bytes32 effectiveSalt = keccak256(abi.encode(bob, SALT));
    address predictedReleaser = vm.computeCreate2Address(
      effectiveSalt,
      keccak256(
        abi.encodePacked(
          type(ExchangeReleaser).creationCode,
          abi.encode(
            address(resource), THRESHOLD, predictedJar, partnerRecipient, address(feeController)
          )
        )
      ),
      address(factory)
    );

    vm.expectEmit(true, true, true, true, address(factory));
    emit IFactory.JarDeployed(predictedJar, predictedReleaser, admin, bob, SALT);

    (address jar, address releaser) = _deploy(bob);
    assertEq(jar, predictedJar);
    assertEq(releaser, predictedReleaser);
  }

  function test_predictJar_matchesDeployment() public {
    address predicted = factory.predictJar(alice, SALT);
    (address jar,) = _deploy(alice);
    assertEq(jar, predicted);
  }

  /// @dev the squatting regression: the same salt from a different sender must yield a
  /// different jar address, so nobody can front-run a partner's predicted address
  function test_deploy_saltIsSenderScoped() public {
    (address jarAlice,) = _deploy(alice);
    (address jarBob,) = _deploy(bob);
    assertTrue(jarAlice != jarBob);
    assertTrue(factory.predictJar(alice, SALT) != factory.predictJar(bob, SALT));
  }

  function test_revert_deploy_saltReuse() public {
    _deploy(alice);
    vm.expectRevert(); // CREATE2 collision on the jar
    _deploy(alice);
  }

  function test_revert_deploy_zeroAdmin() public {
    vm.expectRevert(IFactory.InvalidAdmin.selector);
    factory.deploy(address(resource), partnerRecipient, THRESHOLD, address(0), SALT);
  }

  function test_revert_constructor_zeroFeeController() public {
    vm.expectRevert(IFactory.InvalidFeeController.selector);
    new Factory(address(0));
  }

  function test_deploy_factoryRetainsNoAuthority() public {
    (address jar, address releaser) = _deploy(bob);

    vm.startPrank(address(factory));

    vm.expectRevert("UNAUTHORIZED"); // solmate Owned
    TokenJar(payable(jar)).setReleaser(address(0xbeef));

    vm.expectRevert(IResourceManager.Unauthorized.selector);
    ExchangeReleaser(releaser).setConfig(address(resource), partnerRecipient, 1, 20);

    vm.expectRevert("UNAUTHORIZED");
    ExchangeReleaser(releaser).setConfigSetter(address(0xbeef));

    vm.stopPrank();
  }

  /// @dev end-to-end smoke: fees flow into a factory-deployed jar and release through the
  /// factory-deployed releaser, with the admin able to reconfigure afterward
  function test_deploy_endToEndRelease() public {
    (address jar, address releaser) = _deploy(bob);

    // fees accumulate (ERC20 + native)
    mockToken.mint(jar, INITIAL_TOKEN_AMOUNT);
    vm.deal(jar, 1 ether);

    ExchangeReleaser r = ExchangeReleaser(releaser);
    uint256 nonce = r.nonce();

    vm.startPrank(alice);
    resource.approve(releaser, type(uint256).max);
    r.release(nonce, releaseMockBoth, alice);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(alice.balance, INITIAL_NATIVE_AMOUNT + 1 ether);
    assertEq(resource.balanceOf(partnerRecipient), THRESHOLD);

    // the admin holds config authority post-deploy
    vm.prank(admin);
    r.setConfig(address(resource), partnerRecipient, THRESHOLD * 2, 20);
    assertEq(r.threshold(), THRESHOLD * 2);
  }
}
