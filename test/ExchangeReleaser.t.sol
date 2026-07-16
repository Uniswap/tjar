// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ProtocolFeesTestBase} from "./utils/ProtocolFeesTestBase.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ExchangeReleaser} from "../src/releasers/ExchangeReleaser.sol";
import {INonce} from "../src/interfaces/base/INonce.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";
import {IReleaser} from "../src/interfaces/IReleaser.sol";
import {ReentrantJarToken} from "./mocks/ReentrantJarToken.sol";

contract ExchangeReleaserTest is ProtocolFeesTestBase {
  ExchangeReleaser public releaser;
  address public recipient = makeAddr("RECIPIENT");
  address public configSetter = makeAddr("CONFIG_SETTER");

  function setUp() public override {
    super.setUp();
    // owner is the msg.sender
    vm.startPrank(owner);
    releaser = new ExchangeReleaser(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(feeController)
    );

    tokenJar.setReleaser(address(releaser));
    releaser.setConfigSetter(configSetter);
    vm.stopPrank();
  }

  function test_release_release_erc20() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(recipient), 0);

    vm.startPrank(alice);
    resource.approve(address(releaser), INITIAL_TOKEN_AMOUNT);

    // Expect the Released event
    vm.expectEmit(true, true, false, true, address(releaser));
    emit IReleaser.Released(releaser.nonce(), alice, releaseMockToken);

    releaser.release(releaser.nonce(), releaseMockToken, alice);

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(recipient), releaser.threshold());
  }

  function test_release_release_native() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(recipient), 0);

    vm.startPrank(alice);
    resource.approve(address(releaser), INITIAL_TOKEN_AMOUNT);

    // Expect the Released event
    vm.expectEmit(true, true, false, true, address(releaser));
    emit IReleaser.Released(releaser.nonce(), alice, releaseMockNative);

    releaser.release(releaser.nonce(), releaseMockNative, alice);

    assertEq(CurrencyLibrary.ADDRESS_ZERO.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(recipient), releaser.threshold());
  }

  function test_fuzz_revert_release_insufficient_balance(uint256 amount, uint256 seed) public {
    amount = bound(amount, 1, resource.balanceOf(alice));

    // alice spends some of her resources
    vm.prank(alice);
    bool success = resource.transfer(recipient, amount);
    assertTrue(success);
    assertLt(resource.balanceOf(alice), releaser.threshold());

    uint256 nonce = releaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    vm.expectRevert(); // reverts on token insufficient allowance
    releaser.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice);
  }

  function test_fuzz_revert_release_invalid_nonce(uint256 nonce, uint256 seed) public {
    vm.assume(nonce != releaser.nonce()); // Ensure nonce is not the current nonce

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    vm.expectRevert(INonce.InvalidNonce.selector);
    releaser.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice);
  }

  function test_revert_constructor_zero_fee_controller() public {
    vm.expectRevert(IReleaser.InvalidFeeController.selector);
    new ExchangeReleaser(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(0)
    );
  }

  function test_release_zero_fee_skips_fee_transfer() public {
    // alice holds exactly the threshold; a non-zero fee pull would revert
    assertEq(resource.balanceOf(alice), releaser.threshold());

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(releaser.nonce(), releaseMockToken, alice);

    assertEq(resource.balanceOf(recipient), releaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), 0);
  }

  function test_release_with_protocol_fee() public {
    uint256 feeBps = 500; // 5%
    uint256 fee = releaser.threshold() * feeBps / releaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(alice, fee);

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(releaser.nonce(), releaseMockToken, alice);

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), releaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  function test_fuzz_release_protocol_fee(uint256 feeBps) public {
    feeBps = bound(feeBps, 0, feeController.MAX_FEE_BPS());
    uint256 fee = releaser.threshold() * feeBps / releaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(alice, fee);

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(releaser.nonce(), releaseMockToken, alice);

    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), releaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  /// @dev the fee is read from the controller at release time, so an update between two
  /// releases applies to the second one
  function test_release_fee_reads_live_config() public {
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(releaser.nonce(), releaseMockToken, alice);
    vm.stopPrank();

    assertEq(resource.balanceOf(protocolFeeRecipient), 0);

    uint256 feeBps = 100; // 1%
    uint256 fee = releaser.threshold() * feeBps / releaser.BPS_DENOMINATOR();
    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(bob, releaser.threshold() + fee);

    vm.startPrank(bob);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(releaser.nonce(), releaseMockToken, bob);

    assertEq(resource.balanceOf(bob), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  function test_revert_release_insufficient_balance_for_fee() public {
    vm.prank(owner);
    feeController.setFeeBps(500);

    // alice can cover the threshold but not the fee on top
    assertEq(resource.balanceOf(alice), releaser.threshold());

    uint256 nonce = releaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    vm.expectRevert(); // reverts on token insufficient balance for the fee pull
    releaser.release(nonce, releaseMockToken, alice);
  }

  /// @dev test that two transactions with the same nonce, the second one should revert
  function test_revert_release_frontrun() public {
    uint256 nonce = releaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);

    // First release call - expect the Released event
    vm.expectEmit(true, true, false, true, address(releaser));
    emit IReleaser.Released(nonce, alice, releaseMockToken);

    releaser.release(nonce, releaseMockToken, alice);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(recipient), INITIAL_TOKEN_AMOUNT);

    // Attempt to frontrun with the same nonce
    vm.expectRevert(INonce.InvalidNonce.selector);
    releaser.release(nonce, releaseMockToken, alice);
  }

  /// @dev on a single chain releaser, malicious tokens will hard revert
  function test_revert_release_revertingToken() public {
    uint256 nonce = releaser.nonce();
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);

    vm.expectRevert();
    releaser.release(nonce, releaseMockReverting, alice);
  }

  /// @dev reentrancy is third-party reachable: anyone can donate a malicious token to the jar
  /// and list it in the caller-supplied `assets[]`, so its transfer runs mid-sweep. Reusing the
  /// ORIGINAL nonce in the reentrant call reverts — handleNonce bumps before the body, so the
  /// nonce no longer matches — and the revert unwinds the whole outer release. Nothing moves.
  function test_revert_release_reentrantStaleNonce() public {
    ReentrantJarToken reentrant = new ReentrantJarToken("Reentrant", "RE", 18);
    reentrant.mint(address(tokenJar), 1e18);

    uint256 nonce = releaser.nonce();
    Currency[] memory reentryAssets = new Currency[](1);
    reentryAssets[0] = Currency.wrap(address(mockToken));
    // arm the reentrant call to reuse the SAME nonce alice is releasing at
    reentrant.arm(IReleaser(address(releaser)), nonce, reentryAssets, bob);

    Currency[] memory assets = new Currency[](1);
    assets[0] = Currency.wrap(address(reentrant));

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    // the reentrant call reverts with InvalidNonce; CurrencyLibrary.transfer re-wraps any
    // sweep-time token revert, so the outer failure is a wrapped error rather than the raw
    // selector — the meaningful proof is that the whole release unwound (asserted below)
    vm.expectRevert();
    releaser.release(nonce, assets, alice);
    vm.stopPrank();

    // the outer release fully unwound: nothing paid, nothing swept
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(recipient), 0);
    assertEq(mockToken.balanceOf(address(tokenJar)), INITIAL_TOKEN_AMOUNT);
    assertEq(releaser.nonce(), nonce);
  }

  /// @dev even with the correctly bumped nonce, a mid-sweep reentrant release cannot double-claim
  /// the jar and is strictly unprofitable: each release invocation pays a full threshold BEFORE
  /// it can sweep, and the jar pays each asset against its live balance. Here the reentrant call
  /// drains mockToken to an attacker, but it cost a second full threshold, and the outer call's
  /// listing of mockToken then sweeps nothing (balance already zero). This is the invariant the
  /// natspec on release() pins.
  function test_release_reentrantFreshNonceUnprofitable() public {
    address attacker = makeAddr("ATTACKER");
    ReentrantJarToken reentrant = new ReentrantJarToken("Reentrant", "RE", 18);
    uint256 jarReentrantAmount = 1e18;
    reentrant.mint(address(tokenJar), jarReentrantAmount);

    // the malicious token must itself hold + approve a full threshold to fund its reentrant pull
    resource.mint(address(reentrant), releaser.threshold());
    vm.prank(address(reentrant));
    resource.approve(address(releaser), type(uint256).max);

    uint256 nonce = releaser.nonce();
    Currency[] memory reentryAssets = new Currency[](1);
    reentryAssets[0] = Currency.wrap(address(mockToken));
    // reenter at the bumped nonce, draining mockToken to the attacker
    reentrant.arm(IReleaser(address(releaser)), nonce + 1, reentryAssets, attacker);

    // alice lists [reentrant, mockToken]: the reentry fires while reentrant is swept (i=0)
    Currency[] memory assets = new Currency[](2);
    assets[0] = Currency.wrap(address(reentrant));
    assets[1] = Currency.wrap(address(mockToken));

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(nonce, assets, alice);
    vm.stopPrank();

    // mockToken left the jar exactly once — to the attacker's reentrant call, not twice
    assertEq(mockToken.balanceOf(attacker), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken.balanceOf(alice), 0);
    assertEq(mockToken.balanceOf(address(tokenJar)), 0);
    // alice got only the (worthless) reentrant token she listed
    assertEq(reentrant.balanceOf(alice), jarReentrantAmount);

    // the attack cost TWO full thresholds: alice's and the malicious token's
    assertEq(resource.balanceOf(recipient), releaser.threshold() * 2);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(reentrant)), 0);

    // both invocations advanced the nonce
    assertEq(releaser.nonce(), nonce + 2);
  }

  function test_revert_release_tooManyAssets() public {
    Currency[] memory assets = new Currency[](21);
    for (uint256 i = 0; i < 21; i++) {
      assets[i] = Currency.wrap(address(mockToken));
    }

    uint256 nonce = releaser.nonce();

    vm.expectRevert(IReleaser.TooManyAssets.selector);
    releaser.release(nonce, assets, alice);
  }

  function test_fuzz_setConfigSetter(address caller, address newSetter) public {
    vm.startPrank(caller);
    // only the owner can rotate the role; the configSetter itself cannot
    if (caller != releaser.owner()) vm.expectRevert("UNAUTHORIZED");
    releaser.setConfigSetter(newSetter);
    vm.stopPrank();
  }

  function test_fuzz_revert_setConfig(address caller, uint256 newThreshold) public {
    newThreshold = bound(newThreshold, 1, type(uint256).max); // zero is rejected as InvalidConfig
    vm.startPrank(caller);
    if (caller != releaser.configSetter() && caller != releaser.owner()) {
      vm.expectRevert(IResourceManager.Unauthorized.selector);
    }
    releaser.setConfig(address(resource), recipient, newThreshold, 20);
    vm.stopPrank();
  }

  /// @dev sets only the threshold, keeping the fixture's other config values
  function _setThresholdConfig(address caller, uint256 newThreshold) internal {
    vm.prank(caller);
    releaser.setConfig(address(resource), recipient, newThreshold, 20);
  }

  function test_setConfig_bumpsNonce() public {
    uint256 nonceBefore = releaser.nonce();

    vm.expectEmit(true, true, false, true, address(releaser));
    emit IResourceManager.ConfigSet(address(resource), recipient, 42, 20);

    _setThresholdConfig(configSetter, 42);

    assertEq(releaser.threshold(), 42);
    assertEq(releaser.nonce(), nonceBefore + 1);
  }

  /// @dev "any config txn bumps" is the invariant — a same-value set is not exempt
  function test_setConfig_noopStillBumpsNonce() public {
    uint256 nonceBefore = releaser.nonce();
    uint256 currentThreshold = releaser.threshold();

    _setThresholdConfig(configSetter, currentThreshold);

    assertEq(releaser.threshold(), currentThreshold);
    assertEq(releaser.nonce(), nonceBefore + 1);
  }

  function test_constructor_initialConfig() public view {
    assertEq(address(releaser.resource()), address(resource));
    assertEq(releaser.resourceRecipient(), recipient);
    assertEq(releaser.threshold(), INITIAL_TOKEN_AMOUNT);
    assertEq(releaser.maxReleaseLength(), 20);
    assertEq(releaser.configSetter(), configSetter);
    assertEq(releaser.nonce(), 0); // the constructor does not bump
  }

  function test_revert_constructor_validation() public {
    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    new ExchangeReleaser(
      address(0), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(feeController)
    );

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    new ExchangeReleaser(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), address(0), address(feeController)
    );

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    new ExchangeReleaser(address(resource), 0, address(tokenJar), recipient, address(feeController));

    vm.expectRevert(IReleaser.InvalidTokenJar.selector);
    new ExchangeReleaser(
      address(resource), INITIAL_TOKEN_AMOUNT, address(0), recipient, address(feeController)
    );
  }

  /// @dev the jar must never be the resource recipient: it would let a release caller list the
  /// resource among assets and reclaim the threshold, draining the jar for free. Guarded at
  /// construction by an explicit param check (the base _validateConfig hook cannot catch it —
  /// TOKEN_JAR is unset when the base constructor runs it)
  function test_revert_constructor_recipientIsJar() public {
    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    new ExchangeReleaser(
      address(resource),
      INITIAL_TOKEN_AMOUNT,
      address(tokenJar),
      address(tokenJar),
      address(feeController)
    );
  }

  /// @dev the same invariant is enforced on the setConfig path, where TOKEN_JAR is assigned and
  /// the _validateConfig override does the rejecting
  function test_revert_setConfig_recipientIsJar() public {
    vm.prank(configSetter);
    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    releaser.setConfig(address(resource), address(tokenJar), 42, 20);
  }

  function test_revert_setConfig_validation() public {
    vm.startPrank(configSetter);

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    releaser.setConfig(address(0), recipient, 42, 20);

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    releaser.setConfig(address(resource), address(0), 42, 20);

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    releaser.setConfig(address(resource), recipient, 0, 20);

    vm.expectRevert(IResourceManager.InvalidConfig.selector);
    releaser.setConfig(address(resource), recipient, 42, 0);

    vm.stopPrank();
  }

  /// @dev the headline regression for atomic config: a resource switch cannot let a pending
  /// release pull a token the caller merely happened to have approved
  function test_revert_release_resourceSwitchFrontrun() public {
    uint256 pendingNonce = releaser.nonce();
    uint256 newThreshold = 5e18;

    // alice prepares a release of the current resource, and also happens to have approved
    // mockToken1 (the future resource)
    mockToken1.mint(alice, INITIAL_TOKEN_AMOUNT);
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    mockToken1.approve(address(releaser), type(uint256).max);
    vm.stopPrank();

    // the partner atomically switches resource AND threshold before alice's release lands
    vm.prank(configSetter);
    releaser.setConfig(address(mockToken1), recipient, newThreshold, 20);

    // alice's pending release reverts on the nonce; neither token is pulled
    vm.prank(alice);
    vm.expectRevert(INonce.InvalidNonce.selector);
    releaser.release(pendingNonce, releaseMockToken, alice);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken1.balanceOf(alice), INITIAL_TOKEN_AMOUNT);

    // re-simulated at the current nonce, the release pulls the NEW resource at the NEW threshold
    uint256 currentNonce = releaser.nonce();
    vm.prank(alice);
    releaser.release(currentNonce, releaseMockToken, alice);

    assertEq(mockToken1.balanceOf(alice), INITIAL_TOKEN_AMOUNT - newThreshold);
    assertEq(mockToken1.balanceOf(recipient), newThreshold);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // old resource untouched
  }

  /// @dev the protocol fee is denominated in whatever resource currently is
  function test_release_feeInNewResource() public {
    uint256 feeBps = 500;
    uint256 newThreshold = 100e18;
    uint256 fee = newThreshold * feeBps / releaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    vm.prank(configSetter);
    releaser.setConfig(address(mockToken1), recipient, newThreshold, 20);

    mockToken1.mint(alice, newThreshold + fee);
    uint256 currentNonce = releaser.nonce();

    vm.startPrank(alice);
    mockToken1.approve(address(releaser), type(uint256).max);
    releaser.release(currentNonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(mockToken1.balanceOf(recipient), newThreshold);
    assertEq(mockToken1.balanceOf(protocolFeeRecipient), fee);
    assertEq(mockToken1.balanceOf(alice), 0);
  }

  /// @dev maxReleaseLength governs the TooManyAssets boundary in both directions
  function test_setConfig_maxReleaseLengthBoundary() public {
    Currency[] memory assets = new Currency[](3);
    for (uint256 i = 0; i < 3; i++) {
      assets[i] = Currency.wrap(address(mockToken));
    }

    // lower the cap below the batch size: release reverts
    vm.prank(configSetter);
    releaser.setConfig(address(resource), recipient, INITIAL_TOKEN_AMOUNT, 2);

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    uint256 nonce = releaser.nonce();
    vm.expectRevert(IReleaser.TooManyAssets.selector);
    releaser.release(nonce, assets, alice);
    vm.stopPrank();

    // raise the cap back above it: the same batch releases
    vm.prank(configSetter);
    releaser.setConfig(address(resource), recipient, INITIAL_TOKEN_AMOUNT, 3);

    uint256 freshNonce = releaser.nonce();
    vm.prank(alice);
    releaser.release(freshNonce, assets, alice);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
  }

  /// @dev rotating the configSetter changes who may set terms, not the terms a searcher
  /// priced against — it must NOT invalidate pending releases
  function test_setConfigSetter_doesNotBumpNonce() public {
    uint256 nonceBefore = releaser.nonce();

    vm.prank(owner);
    releaser.setConfigSetter(makeAddr("ANOTHER_SETTER"));

    assertEq(releaser.nonce(), nonceBefore);
  }

  /// @dev the headline safety property: a config change landing before a pending release
  /// makes the release revert instead of executing at terms the caller never priced
  function test_revert_release_configChangeFrontrun() public {
    uint256 pendingNonce = releaser.nonce();

    vm.prank(alice);
    resource.approve(address(releaser), type(uint256).max);

    // a threshold increase front-runs alice's pending release
    _setThresholdConfig(configSetter, INITIAL_TOKEN_AMOUNT * 2);

    // the release simulated against the old terms reverts on the nonce
    vm.prank(alice);
    vm.expectRevert(INonce.InvalidNonce.selector);
    releaser.release(pendingNonce, releaseMockToken, alice);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // nothing was pulled

    // re-simulating at the current nonce executes at the new terms
    deal(address(resource), alice, INITIAL_TOKEN_AMOUNT * 2);
    uint256 currentNonce = releaser.nonce();

    vm.prank(alice);
    releaser.release(currentNonce, releaseMockToken, alice);

    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), INITIAL_TOKEN_AMOUNT * 2);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
  }

  function test_setConfig_asOwner() public {
    // the owner can set the config directly without holding the configSetter role
    assertTrue(releaser.configSetter() != owner);

    _setThresholdConfig(owner, 42);
    assertEq(releaser.threshold(), 42);
  }

  function test_setConfig_asConfigSetter() public {
    _setThresholdConfig(configSetter, 42);
    assertEq(releaser.threshold(), 42);
  }

  function test_setConfigSetter_emitsEvent() public {
    address newSetter = makeAddr("NEW_SETTER");

    vm.expectEmit(true, true, false, true, address(releaser));
    emit IResourceManager.ConfigSetterSet(configSetter, newSetter);

    vm.prank(owner);
    releaser.setConfigSetter(newSetter);
    assertEq(releaser.configSetter(), newSetter);
  }

  function test_setConfigSetter_revoke() public {
    // revoking the role locks out the old configSetter but the owner can still act
    vm.expectEmit(true, true, false, true, address(releaser));
    emit IResourceManager.ConfigSetterSet(configSetter, address(0));

    vm.prank(owner);
    releaser.setConfigSetter(address(0));

    vm.prank(configSetter);
    vm.expectRevert(IResourceManager.Unauthorized.selector);
    releaser.setConfig(address(resource), recipient, 42, 20);

    _setThresholdConfig(owner, 42);
    assertEq(releaser.threshold(), 42);
  }

  function test_fuzz_newThreshold(uint256 newThreshold) public {
    newThreshold = bound(newThreshold, 1, type(uint256).max); // zero is rejected as InvalidConfig
    vm.assume(newThreshold != releaser.threshold());

    _setThresholdConfig(owner, newThreshold);

    deal(address(resource), alice, newThreshold);

    assertEq(resource.balanceOf(alice), newThreshold);
    assertEq(resource.balanceOf(recipient), 0);

    uint256 currentNonce = releaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(releaser), newThreshold);
    releaser.release(currentNonce, releaseMockBoth, alice);

    assertEq(releaser.nonce(), currentNonce + 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), releaser.threshold());
  }
}
