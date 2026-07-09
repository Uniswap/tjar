// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ProtocolFeesTestBase} from "./utils/ProtocolFeesTestBase.sol";
import {Factory} from "../src/Factory.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";
import {TokenJar, ITokenJar} from "../src/TokenJar.sol";
import {ExchangeReleaser} from "../src/releasers/ExchangeReleaser.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";

contract FactoryTest is ProtocolFeesTestBase {
  Factory public factory;
  address public admin = makeAddr("ADMIN");
  address public configSetter = makeAddr("CONFIG_SETTER");
  address public partnerRecipient = makeAddr("PARTNER_RECIPIENT");
  bytes32 public constant SALT = keccak256("partner-1");
  uint256 public constant THRESHOLD = 100e18;

  function setUp() public override {
    super.setUp();
    factory = new Factory(address(feeController));
  }

  function _deploy(address caller) internal returns (address jar, address releaser) {
    vm.prank(caller);
    return factory.deploy(address(resource), partnerRecipient, THRESHOLD, admin, configSetter, SALT);
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
    assertEq(r.configSetter(), configSetter);
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
    emit IFactory.JarDeployed(predictedJar, predictedReleaser, admin, configSetter, bob, SALT);

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

  function test_revert_deploy_zeroOwner() public {
    vm.expectRevert(IFactory.InvalidOwner.selector);
    factory.deploy(address(resource), partnerRecipient, THRESHOLD, address(0), configSetter, SALT);
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

  function test_deployReleaser_wiresEverything() public {
    (address jar, address originalReleaser) = _deploy(bob);

    vm.prank(bob);
    address newReleaser = factory.deployReleaser(
      jar,
      address(resource),
      partnerRecipient,
      THRESHOLD * 2,
      admin,
      configSetter,
      keccak256("rotation-1")
    );

    ExchangeReleaser r = ExchangeReleaser(newReleaser);
    assertEq(address(r.TOKEN_JAR()), jar);
    assertEq(address(r.FEE_CONTROLLER()), address(feeController));
    assertEq(address(r.resource()), address(resource));
    assertEq(r.resourceRecipient(), partnerRecipient);
    assertEq(r.threshold(), THRESHOLD * 2);
    assertEq(r.maxReleaseLength(), 20);
    assertEq(r.owner(), admin);
    assertEq(r.configSetter(), configSetter);
    assertEq(r.nonce(), 0);

    // inert until adopted: the jar still points at the original releaser
    assertEq(TokenJar(payable(jar)).releaser(), originalReleaser);
  }

  function test_deployReleaser_emitsEvent() public {
    (address jar,) = _deploy(bob);
    bytes32 rotationSalt = keccak256("rotation-1");

    bytes32 effectiveSalt = keccak256(abi.encode(bob, rotationSalt));
    address predictedReleaser = vm.computeCreate2Address(
      effectiveSalt,
      keccak256(
        abi.encodePacked(
          type(ExchangeReleaser).creationCode,
          abi.encode(address(resource), THRESHOLD, jar, partnerRecipient, address(feeController))
        )
      ),
      address(factory)
    );

    vm.expectEmit(true, true, true, true, address(factory));
    emit IFactory.ReleaserDeployed(jar, predictedReleaser, admin, configSetter, bob, rotationSalt);

    vm.prank(bob);
    address releaser = factory.deployReleaser(
      jar, address(resource), partnerRecipient, THRESHOLD, admin, configSetter, rotationSalt
    );
    assertEq(releaser, predictedReleaser);
  }

  function test_deployReleaser_saltIsSenderScoped() public {
    (address jar,) = _deploy(bob);
    bytes32 rotationSalt = keccak256("rotation-1");

    // identical args from different senders must yield different releaser addresses
    vm.prank(alice);
    address fromAlice = factory.deployReleaser(
      jar, address(resource), partnerRecipient, THRESHOLD, admin, configSetter, rotationSalt
    );
    vm.prank(bob);
    address fromBob = factory.deployReleaser(
      jar, address(resource), partnerRecipient, THRESHOLD, admin, configSetter, rotationSalt
    );
    assertTrue(fromAlice != fromBob);
  }

  function test_revert_deployReleaser_zeroOwner() public {
    (address jar,) = _deploy(bob);
    vm.expectRevert(IFactory.InvalidOwner.selector);
    factory.deployReleaser(
      jar, address(resource), partnerRecipient, THRESHOLD, address(0), configSetter, SALT
    );
  }

  function test_deploy_zeroConfigSetter_leavesRoleUnset() public {
    vm.prank(bob);
    (, address releaser) =
      factory.deploy(address(resource), partnerRecipient, THRESHOLD, admin, address(0), SALT);

    ExchangeReleaser r = ExchangeReleaser(releaser);
    assertEq(r.configSetter(), address(0));
    assertEq(r.owner(), admin);

    // owner-only config still works
    vm.prank(admin);
    r.setConfig(address(resource), partnerRecipient, THRESHOLD * 2, 20);
    assertEq(r.threshold(), THRESHOLD * 2);
  }

  /// @dev owner = 0xdead + configSetter = 0 relinquishes everything atomically at deployment:
  /// no key ever holds power over the pair, yet releases keep working (the trustless burn tier
  /// from the README, in a single transaction)
  function test_deploy_trustlessFromBirth() public {
    vm.prank(bob);
    (address jar, address releaser) = factory.deploy(
      address(resource), address(0xdead), THRESHOLD, address(0xdead), address(0), SALT
    );

    ExchangeReleaser r = ExchangeReleaser(releaser);
    assertEq(TokenJar(payable(jar)).owner(), address(0xdead));
    assertEq(r.owner(), address(0xdead));
    assertEq(r.configSetter(), address(0));

    // nobody can reconfigure the releaser or rotate the jar
    vm.startPrank(bob);
    vm.expectRevert(IResourceManager.Unauthorized.selector);
    r.setConfig(address(resource), address(0xdead), 1, 20);
    vm.expectRevert("UNAUTHORIZED");
    TokenJar(payable(jar)).setReleaser(address(0xbeef));
    vm.stopPrank();

    // but releases still work
    mockToken.mint(jar, INITIAL_TOKEN_AMOUNT);
    uint256 nonce = r.nonce();
    vm.startPrank(alice);
    resource.approve(releaser, type(uint256).max);
    r.release(nonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(0xdead)), THRESHOLD);
  }

  /// @dev an unadopted releaser cannot pull from the jar: release reverts inside jar.release
  /// (after the resource pull, so the whole tx unwinds)
  function test_revert_release_unadoptedReleaser() public {
    (address jar,) = _deploy(bob);

    vm.prank(bob);
    address newReleaser = factory.deployReleaser(
      jar,
      address(resource),
      partnerRecipient,
      THRESHOLD,
      admin,
      configSetter,
      keccak256("rotation-1")
    );
    mockToken.mint(jar, INITIAL_TOKEN_AMOUNT);

    vm.startPrank(alice);
    resource.approve(newReleaser, type(uint256).max);
    vm.expectRevert(ITokenJar.Unauthorized.selector);
    ExchangeReleaser(newReleaser).release(0, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // nothing was pulled
  }

  /// @dev the full rotation flow: deployReleaser, jar owner adopts via setReleaser, a pending
  /// release against the old releaser reverts, and the new releaser releases at the new terms
  function test_deployReleaser_rotation_endToEnd() public {
    (address jar, address oldReleaser) = _deploy(bob);
    mockToken.mint(jar, INITIAL_TOKEN_AMOUNT);

    // a searcher lines up a release against the old releaser
    uint256 pendingNonce = ExchangeReleaser(oldReleaser).nonce();
    vm.startPrank(alice);
    resource.approve(oldReleaser, type(uint256).max);
    vm.stopPrank();

    // step 1: partner deploys the replacement releaser at new terms
    uint256 newThreshold = THRESHOLD * 2;
    vm.prank(admin);
    address newReleaser = factory.deployReleaser(
      jar,
      address(resource),
      partnerRecipient,
      newThreshold,
      admin,
      configSetter,
      keccak256("rotation-1")
    );

    // step 2: the jar owner adopts it (atomic with step 1 when the admin is a Safe)
    vm.prank(admin);
    TokenJar(payable(jar)).setReleaser(newReleaser);

    // the old releaser's pending release now reverts inside jar.release; nothing is pulled
    vm.prank(alice);
    vm.expectRevert(ITokenJar.Unauthorized.selector);
    ExchangeReleaser(oldReleaser).release(pendingNonce, releaseMockToken, alice);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);

    // the searcher re-simulates against the new releaser and releases at the new terms
    resource.mint(alice, newThreshold);
    uint256 freshNonce = ExchangeReleaser(newReleaser).nonce();
    vm.startPrank(alice);
    resource.approve(newReleaser, type(uint256).max);
    ExchangeReleaser(newReleaser).release(freshNonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(partnerRecipient), newThreshold);
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
