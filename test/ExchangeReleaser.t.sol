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

  function test_fuzz_revert_setThreshold(address caller, uint256 newThreshold) public {
    vm.startPrank(caller);
    if (caller != swapReleaser.configSetter() && caller != swapReleaser.owner()) {
      vm.expectRevert(IResourceManager.Unauthorized.selector);
    }
    swapReleaser.setThreshold(newThreshold);
    vm.stopPrank();
  }

  function test_setThreshold_asOwner() public {
    // the owner can set the threshold directly without holding the configSetter role
    assertTrue(swapReleaser.configSetter() != owner);

    vm.prank(owner);
    swapReleaser.setThreshold(42);
    assertEq(swapReleaser.threshold(), 42);
  }

  function test_setThreshold_asConfigSetter() public {
    vm.prank(configSetter);
    swapReleaser.setThreshold(42);
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
    swapReleaser.setThreshold(42);

    vm.prank(owner);
    swapReleaser.setThreshold(42);
    assertEq(swapReleaser.threshold(), 42);
  }

  function test_fuzz_newThreshold(uint256 newThreshold) public {
    vm.assume(newThreshold != swapReleaser.threshold());

    vm.prank(owner);
    swapReleaser.setThreshold(newThreshold);

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
