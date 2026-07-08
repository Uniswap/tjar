// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ProtocolFeesTestBase} from "./utils/ProtocolFeesTestBase.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ExchangeReleaserMock} from "./mocks/ExchangeReleaserMock.sol";
import {INonce} from "../src/interfaces/base/INonce.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";
import {IReleaser} from "../src/interfaces/IReleaser.sol";

contract ExchangeReleaserTest is ProtocolFeesTestBase {
  ExchangeReleaserMock public swapReleaser;
  address public recipient = makeAddr("RECIPIENT");
  address public configSetter = makeAddr("CONFIG_SETTER");

  function setUp() public override {
    super.setUp();
    // owner is the msg.sender
    vm.startPrank(owner);
    swapReleaser = new ExchangeReleaserMock(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(feeController)
    );

    tokenJar.setReleaser(address(swapReleaser));
    swapReleaser.setConfigSetter(configSetter);
    vm.stopPrank();
  }

  function test_release_release_erc20() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(swapReleaser)), 0);
    assertEq(resource.balanceOf(recipient), 0);

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), INITIAL_TOKEN_AMOUNT);

    // Expect the Released event
    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IReleaser.Released(swapReleaser.nonce(), alice, releaseMockToken);

    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, alice);

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(swapReleaser)), 0);
    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
  }

  function test_release_release_native() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(swapReleaser)), 0);
    assertEq(resource.balanceOf(recipient), 0);

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), INITIAL_TOKEN_AMOUNT);

    // Expect the Released event
    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IReleaser.Released(swapReleaser.nonce(), alice, releaseMockNative);

    swapReleaser.release(swapReleaser.nonce(), releaseMockNative, alice);

    assertEq(CurrencyLibrary.ADDRESS_ZERO.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(swapReleaser)), 0);
    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
  }

  function test_fuzz_revert_release_insufficient_balance(uint256 amount, uint256 seed) public {
    amount = bound(amount, 1, resource.balanceOf(alice));

    // alice spends some of her resources
    vm.prank(alice);
    bool success = resource.transfer(recipient, amount);
    assertTrue(success);
    assertLt(resource.balanceOf(alice), swapReleaser.threshold());

    uint256 nonce = swapReleaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    vm.expectRevert(); // reverts on token insufficient allowance
    swapReleaser.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice);
  }

  function test_fuzz_revert_release_invalid_nonce(uint256 nonce, uint256 seed) public {
    vm.assume(nonce != swapReleaser.nonce()); // Ensure nonce is not the current nonce

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    vm.expectRevert(INonce.InvalidNonce.selector);
    swapReleaser.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice);
  }

  function test_revert_constructor_zero_fee_controller() public {
    vm.expectRevert(IReleaser.InvalidFeeController.selector);
    new ExchangeReleaserMock(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(0)
    );
  }

  function test_release_zero_fee_skips_fee_transfer() public {
    // alice holds exactly the threshold; a non-zero fee pull would revert
    assertEq(resource.balanceOf(alice), swapReleaser.threshold());

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, alice);

    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), 0);
  }

  function test_release_with_protocol_fee() public {
    uint256 feeBps = 500; // 5%
    uint256 fee = swapReleaser.threshold() * feeBps / swapReleaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(alice, fee);

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, alice);

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  function test_fuzz_release_protocol_fee(uint256 feeBps) public {
    feeBps = bound(feeBps, 0, feeController.MAX_FEE_BPS());
    uint256 fee = swapReleaser.threshold() * feeBps / swapReleaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(alice, fee);

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, alice);

    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  /// @dev the fee is read from the controller at release time, so an update between two
  /// releases applies to the second one
  function test_release_fee_reads_live_config() public {
    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, alice);
    vm.stopPrank();

    assertEq(resource.balanceOf(protocolFeeRecipient), 0);

    uint256 feeBps = 100; // 1%
    uint256 fee = swapReleaser.threshold() * feeBps / swapReleaser.BPS_DENOMINATOR();
    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    resource.mint(bob, swapReleaser.threshold() + fee);

    vm.startPrank(bob);
    resource.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(swapReleaser.nonce(), releaseMockToken, bob);

    assertEq(resource.balanceOf(bob), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
  }

  function test_revert_release_insufficient_balance_for_fee() public {
    vm.prank(owner);
    feeController.setFeeBps(500);

    // alice can cover the threshold but not the fee on top
    assertEq(resource.balanceOf(alice), swapReleaser.threshold());

    uint256 nonce = swapReleaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    vm.expectRevert(); // reverts on token insufficient balance for the fee pull
    swapReleaser.release(nonce, releaseMockToken, alice);
  }

  /// @dev test that two transactions with the same nonce, the second one should revert
  function test_revert_release_frontrun() public {
    uint256 nonce = swapReleaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);

    // First release call - expect the Released event
    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IReleaser.Released(nonce, alice, releaseMockToken);

    swapReleaser.release(nonce, releaseMockToken, alice);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken.balanceOf(address(tokenJar)), 0);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(swapReleaser)), 0);
    assertEq(resource.balanceOf(recipient), INITIAL_TOKEN_AMOUNT);

    // Attempt to frontrun with the same nonce
    vm.expectRevert(INonce.InvalidNonce.selector);
    swapReleaser.release(nonce, releaseMockToken, alice);
  }

  /// @dev on a single chain releaser, malicious tokens will hard revert
  function test_revert_release_revertingToken() public {
    uint256 nonce = swapReleaser.nonce();
    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);

    vm.expectRevert();
    swapReleaser.release(nonce, releaseMockReverting, alice);
  }

  function test_revert_release_tooManyAssets() public {
    Currency[] memory assets = new Currency[](21);
    for (uint256 i = 0; i < 21; i++) {
      assets[i] = Currency.wrap(address(mockToken));
    }

    uint256 nonce = swapReleaser.nonce();

    vm.expectRevert(IReleaser.TooManyAssets.selector);
    swapReleaser.release(nonce, assets, alice);
  }

  function test_fuzz_setConfigSetter(address caller, address newSetter) public {
    vm.startPrank(caller);
    // only the owner can rotate the role; the configSetter itself cannot
    if (caller != swapReleaser.owner()) vm.expectRevert("UNAUTHORIZED");
    swapReleaser.setConfigSetter(newSetter);
    vm.stopPrank();
  }

  function test_fuzz_revert_setConfig(address caller, uint256 newThreshold) public {
    vm.startPrank(caller);
    if (caller != swapReleaser.configSetter() && caller != swapReleaser.owner()) {
      vm.expectRevert(IResourceManager.Unauthorized.selector);
    }
    swapReleaser.setConfig(address(resource), recipient, newThreshold, 20);
    vm.stopPrank();
  }

  /// @dev sets only the threshold, keeping the fixture's other config values
  function _setThresholdConfig(address caller, uint256 newThreshold) internal {
    vm.prank(caller);
    swapReleaser.setConfig(address(resource), recipient, newThreshold, 20);
  }

  function test_setConfig_bumpsNonce() public {
    uint256 nonceBefore = swapReleaser.nonce();

    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IResourceManager.ConfigSet(address(resource), recipient, 42, 20);

    _setThresholdConfig(configSetter, 42);

    assertEq(swapReleaser.threshold(), 42);
    assertEq(swapReleaser.nonce(), nonceBefore + 1);
  }

  /// @dev "any config txn bumps" is the invariant — a same-value set is not exempt
  function test_setConfig_noopStillBumpsNonce() public {
    uint256 nonceBefore = swapReleaser.nonce();
    uint256 currentThreshold = swapReleaser.threshold();

    _setThresholdConfig(configSetter, currentThreshold);

    assertEq(swapReleaser.threshold(), currentThreshold);
    assertEq(swapReleaser.nonce(), nonceBefore + 1);
  }

  function test_constructor_initialConfig() public view {
    assertEq(address(swapReleaser.resource()), address(resource));
    assertEq(swapReleaser.resourceRecipient(), recipient);
    assertEq(swapReleaser.threshold(), INITIAL_TOKEN_AMOUNT);
    assertEq(swapReleaser.maxReleaseLength(), 20);
    assertEq(swapReleaser.configSetter(), configSetter);
    assertEq(swapReleaser.nonce(), 0); // the constructor does not bump
  }

  function test_revert_constructor_validation() public {
    vm.expectRevert(IResourceManager.InvalidResource.selector);
    new ExchangeReleaserMock(
      address(0), INITIAL_TOKEN_AMOUNT, address(tokenJar), recipient, address(feeController)
    );

    vm.expectRevert(IResourceManager.InvalidResourceRecipient.selector);
    new ExchangeReleaserMock(
      address(resource), INITIAL_TOKEN_AMOUNT, address(tokenJar), address(0), address(feeController)
    );

    vm.expectRevert(IReleaser.InvalidTokenJar.selector);
    new ExchangeReleaserMock(
      address(resource), INITIAL_TOKEN_AMOUNT, address(0), recipient, address(feeController)
    );
  }

  function test_revert_setConfig_validation() public {
    vm.startPrank(configSetter);

    vm.expectRevert(IResourceManager.InvalidResource.selector);
    swapReleaser.setConfig(address(0), recipient, 42, 20);

    vm.expectRevert(IResourceManager.InvalidResourceRecipient.selector);
    swapReleaser.setConfig(address(resource), address(0), 42, 20);

    vm.expectRevert(IResourceManager.InvalidMaxReleaseLength.selector);
    swapReleaser.setConfig(address(resource), recipient, 42, 0);

    vm.stopPrank();
  }

  /// @dev the headline regression for atomic config: a resource switch cannot let a pending
  /// release pull a token the caller merely happened to have approved
  function test_revert_release_resourceSwitchFrontrun() public {
    uint256 pendingNonce = swapReleaser.nonce();
    uint256 newThreshold = 5e18;

    // alice prepares a release of the current resource, and also happens to have approved
    // mockToken1 (the future resource)
    mockToken1.mint(alice, INITIAL_TOKEN_AMOUNT);
    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    mockToken1.approve(address(swapReleaser), type(uint256).max);
    vm.stopPrank();

    // the partner atomically switches resource AND threshold before alice's release lands
    vm.prank(configSetter);
    swapReleaser.setConfig(address(mockToken1), recipient, newThreshold, 20);

    // alice's pending release reverts on the nonce; neither token is pulled
    vm.prank(alice);
    vm.expectRevert(INonce.InvalidNonce.selector);
    swapReleaser.release(pendingNonce, releaseMockToken, alice);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(mockToken1.balanceOf(alice), INITIAL_TOKEN_AMOUNT);

    // re-simulated at the current nonce, the release pulls the NEW resource at the NEW threshold
    uint256 currentNonce = swapReleaser.nonce();
    vm.prank(alice);
    swapReleaser.release(currentNonce, releaseMockToken, alice);

    assertEq(mockToken1.balanceOf(alice), INITIAL_TOKEN_AMOUNT - newThreshold);
    assertEq(mockToken1.balanceOf(recipient), newThreshold);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // old resource untouched
  }

  /// @dev the protocol fee is denominated in whatever resource currently is
  function test_release_feeInNewResource() public {
    uint256 feeBps = 500;
    uint256 newThreshold = 100e18;
    uint256 fee = newThreshold * feeBps / swapReleaser.BPS_DENOMINATOR();

    vm.prank(owner);
    feeController.setFeeBps(feeBps);

    vm.prank(configSetter);
    swapReleaser.setConfig(address(mockToken1), recipient, newThreshold, 20);

    mockToken1.mint(alice, newThreshold + fee);
    uint256 currentNonce = swapReleaser.nonce();

    vm.startPrank(alice);
    mockToken1.approve(address(swapReleaser), type(uint256).max);
    swapReleaser.release(currentNonce, releaseMockToken, alice);
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
    swapReleaser.setConfig(address(resource), recipient, INITIAL_TOKEN_AMOUNT, 2);

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);
    uint256 nonce = swapReleaser.nonce();
    vm.expectRevert(IReleaser.TooManyAssets.selector);
    swapReleaser.release(nonce, assets, alice);
    vm.stopPrank();

    // raise the cap back above it: the same batch releases
    vm.prank(configSetter);
    swapReleaser.setConfig(address(resource), recipient, INITIAL_TOKEN_AMOUNT, 3);

    uint256 freshNonce = swapReleaser.nonce();
    vm.prank(alice);
    swapReleaser.release(freshNonce, assets, alice);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
  }

  /// @dev rotating the configSetter changes who may set terms, not the terms a searcher
  /// priced against — it must NOT invalidate pending releases
  function test_setConfigSetter_doesNotBumpNonce() public {
    uint256 nonceBefore = swapReleaser.nonce();

    vm.prank(owner);
    swapReleaser.setConfigSetter(makeAddr("ANOTHER_SETTER"));

    assertEq(swapReleaser.nonce(), nonceBefore);
  }

  /// @dev the headline safety property: a config change landing before a pending release
  /// makes the release revert instead of executing at terms the caller never priced
  function test_revert_release_configChangeFrontrun() public {
    uint256 pendingNonce = swapReleaser.nonce();

    vm.prank(alice);
    resource.approve(address(swapReleaser), type(uint256).max);

    // a threshold increase front-runs alice's pending release
    _setThresholdConfig(configSetter, INITIAL_TOKEN_AMOUNT * 2);

    // the release simulated against the old terms reverts on the nonce
    vm.prank(alice);
    vm.expectRevert(INonce.InvalidNonce.selector);
    swapReleaser.release(pendingNonce, releaseMockToken, alice);
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // nothing was pulled

    // re-simulating at the current nonce executes at the new terms
    deal(address(resource), alice, INITIAL_TOKEN_AMOUNT * 2);
    uint256 currentNonce = swapReleaser.nonce();

    vm.prank(alice);
    swapReleaser.release(currentNonce, releaseMockToken, alice);

    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), INITIAL_TOKEN_AMOUNT * 2);
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
  }

  function test_setConfig_asOwner() public {
    // the owner can set the config directly without holding the configSetter role
    assertTrue(swapReleaser.configSetter() != owner);

    _setThresholdConfig(owner, 42);
    assertEq(swapReleaser.threshold(), 42);
  }

  function test_setConfig_asConfigSetter() public {
    _setThresholdConfig(configSetter, 42);
    assertEq(swapReleaser.threshold(), 42);
  }

  function test_setConfigSetter_emitsEvent() public {
    address newSetter = makeAddr("NEW_SETTER");

    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IResourceManager.ConfigSetterSet(configSetter, newSetter);

    vm.prank(owner);
    swapReleaser.setConfigSetter(newSetter);
    assertEq(swapReleaser.configSetter(), newSetter);
  }

  function test_setConfigSetter_revoke() public {
    // revoking the role locks out the old configSetter but the owner can still act
    vm.expectEmit(true, true, false, true, address(swapReleaser));
    emit IResourceManager.ConfigSetterSet(configSetter, address(0));

    vm.prank(owner);
    swapReleaser.setConfigSetter(address(0));

    vm.prank(configSetter);
    vm.expectRevert(IResourceManager.Unauthorized.selector);
    swapReleaser.setConfig(address(resource), recipient, 42, 20);

    _setThresholdConfig(owner, 42);
    assertEq(swapReleaser.threshold(), 42);
  }

  function test_fuzz_newThreshold(uint256 newThreshold) public {
    vm.assume(newThreshold != swapReleaser.threshold());

    _setThresholdConfig(owner, newThreshold);

    deal(address(resource), alice, newThreshold);

    assertEq(resource.balanceOf(alice), newThreshold);
    assertEq(resource.balanceOf(recipient), 0);

    uint256 currentNonce = swapReleaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(swapReleaser), newThreshold);
    swapReleaser.release(currentNonce, releaseMockBoth, alice);

    assertEq(swapReleaser.nonce(), currentNonce + 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(recipient), swapReleaser.threshold());
  }
}
