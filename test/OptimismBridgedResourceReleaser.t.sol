// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {
  OptimismBridgedResourceReleaser
} from "../src/releasers/OptimismBridgedResourceReleaser.sol";
import {TokenJar} from "../src/TokenJar.sol";
import {FeeController} from "../src/FeeController.sol";
import {INonce} from "../src/interfaces/base/INonce.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";
import {IL2StandardBridge} from "../src/interfaces/external/IL2StandardBridge.sol";

/// @dev Test subclass that approves the bridge for the mock resource. On real OP-stack chains
/// the resource is an OptimismMintableERC20, which the bridge burns without an allowance.
contract TestOptimismBridgedResourceReleaser is OptimismBridgedResourceReleaser {
  constructor(
    address _resource,
    uint256 _threshold,
    address _tokenJar,
    address _feeController,
    address _l1ResourceRecipient
  )
    OptimismBridgedResourceReleaser(
      _resource, _threshold, _tokenJar, _feeController, _l1ResourceRecipient
    )
  {
    MockERC20(_resource).approve(0x4200000000000000000000000000000000000010, type(uint256).max);
  }
}

/// @dev Mock L2StandardBridge: pulls the withdrawn tokens to simulate the bridge taking custody
contract MockL2StandardBridge is IL2StandardBridge {
  event Withdrawn(
    address indexed l2Token,
    address indexed from,
    address indexed to,
    uint256 amount,
    uint32 minGasLimit,
    bytes extraData
  );

  function bridgeETHTo(address, uint32, bytes calldata) external payable override {
    revert("Not implemented");
  }

  function withdrawTo(
    address _l2Token,
    address _to,
    uint256 _amount,
    uint32 _minGasLimit,
    bytes calldata _extraData
  ) external override {
    MockERC20(_l2Token).transferFrom(msg.sender, address(this), _amount);
    emit Withdrawn(_l2Token, msg.sender, _to, _amount, _minGasLimit, _extraData);
  }
}

contract OptimismBridgedResourceReleaserTest is Test {
  address internal constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
  address internal constant L1_BURN = address(0xdead);

  TestOptimismBridgedResourceReleaser internal releaser;
  TokenJar internal tokenJar;
  FeeController internal feeController;
  MockERC20 internal resource;
  MockERC20 internal mockToken;

  address internal alice = makeAddr("alice");
  address internal configSetter = makeAddr("configSetter");
  address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");
  address internal l1OpsWallet = makeAddr("l1OpsWallet");

  uint256 internal constant INITIAL_THRESHOLD = 100e18;
  uint256 internal constant INITIAL_TOKEN_AMOUNT = 1000e18;

  Currency[] internal releaseMockToken;

  function setUp() public {
    resource = new MockERC20("Resource", "RSC", 18);
    mockToken = new MockERC20("MockToken", "MTK", 18);

    // put the mock bridge's code at the OP-stack predeploy address
    MockL2StandardBridge mockBridge = new MockL2StandardBridge();
    vm.etch(L2_STANDARD_BRIDGE, address(mockBridge).code);

    // deployer (this test) is the owner of everything
    tokenJar = new TokenJar();
    feeController = new FeeController(address(this));
    feeController.setFeeRecipient(protocolFeeRecipient);
    releaser = new TestOptimismBridgedResourceReleaser(
      address(resource), INITIAL_THRESHOLD, address(tokenJar), address(feeController), l1OpsWallet
    );

    tokenJar.setReleaser(address(releaser));
    releaser.setConfigSetter(configSetter);

    mockToken.mint(address(tokenJar), INITIAL_TOKEN_AMOUNT);
    resource.mint(alice, INITIAL_TOKEN_AMOUNT);

    releaseMockToken.push(Currency.wrap(address(mockToken)));
  }

  function test_constructor() public view {
    assertEq(address(releaser.resource()), address(resource));
    assertEq(releaser.resourceRecipient(), address(releaser)); // pinned to self
    assertEq(releaser.l1ResourceRecipient(), l1OpsWallet);
    assertEq(releaser.threshold(), INITIAL_THRESHOLD);
    assertEq(releaser.maxReleaseLength(), 20);
    assertEq(releaser.owner(), address(this));
    assertEq(releaser.configSetter(), configSetter);
    assertEq(releaser.nonce(), 0);
  }

  /// @dev stage 1 end-to-end: the redeemer pays the resource here, the jar releases to the
  /// redeemer, and the full resource balance is bridged toward the L1 recipient (an ops
  /// wallet in this fixture — e.g. USDC revenue delivered to a mainnet treasury)
  function test_release_bridgesFullBalance() public {
    uint256 nonce = releaser.nonce();

    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);

    vm.expectEmit(true, true, true, true, L2_STANDARD_BRIDGE);
    emit MockL2StandardBridge.Withdrawn(
      address(resource), address(releaser), l1OpsWallet, INITIAL_THRESHOLD, 100_000, bytes("")
    );

    releaser.release(nonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT); // jar assets released
    assertEq(resource.balanceOf(address(releaser)), 0); // nothing left behind on L2
    assertEq(resource.balanceOf(L2_STANDARD_BRIDGE), INITIAL_THRESHOLD); // custody with bridge
  }

  /// @dev dust or donations sitting on the releaser are swept into the same withdrawal
  function test_release_sweepsDustIntoBridge() public {
    uint256 dust = 7e17;
    resource.mint(address(releaser), dust);

    uint256 nonce = releaser.nonce();
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(nonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(resource.balanceOf(address(releaser)), 0);
    assertEq(resource.balanceOf(L2_STANDARD_BRIDGE), INITIAL_THRESHOLD + dust);
  }

  /// @dev the protocol fee goes to the fee recipient in the resource and is NOT bridged
  function test_release_withProtocolFee() public {
    uint256 feeBps = 500;
    feeController.setFeeBps(feeBps);
    uint256 fee = INITIAL_THRESHOLD * feeBps / releaser.BPS_DENOMINATOR();

    uint256 nonce = releaser.nonce();
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);
    releaser.release(nonce, releaseMockToken, alice);
    vm.stopPrank();

    assertEq(resource.balanceOf(protocolFeeRecipient), fee);
    assertEq(resource.balanceOf(L2_STANDARD_BRIDGE), INITIAL_THRESHOLD); // fee not bridged
  }

  /// @dev threshold and maxReleaseLength stay tunable through the usual atomic setConfig
  function test_setConfig_thresholdMutable() public {
    uint256 nonceBefore = releaser.nonce();

    vm.prank(configSetter);
    releaser.setConfig(address(resource), address(releaser), INITIAL_THRESHOLD * 2, 10);

    assertEq(releaser.threshold(), INITIAL_THRESHOLD * 2);
    assertEq(releaser.maxReleaseLength(), 10);
    assertEq(releaser.nonce(), nonceBefore + 1); // config change bumps as usual
  }

  /// @dev the resource is frozen after construction — a different bridged resource means a
  /// fresh releaser and a jar rotation
  function test_revert_setConfig_resourceFrozen() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH", 18);

    vm.prank(configSetter);
    vm.expectRevert(OptimismBridgedResourceReleaser.ResourceFrozen.selector);
    releaser.setConfig(address(otherToken), address(releaser), INITIAL_THRESHOLD, 20);
  }

  /// @dev resourceRecipient is pinned to the releaser itself — the two-stage burn breaks if
  /// the resource is collected anywhere else
  function test_revert_setConfig_recipientNotSelf() public {
    vm.prank(configSetter);
    vm.expectRevert(OptimismBridgedResourceReleaser.RecipientNotSelf.selector);
    releaser.setConfig(address(resource), alice, INITIAL_THRESHOLD, 20);

    // the owner cannot escape the pin either
    vm.expectRevert(OptimismBridgedResourceReleaser.RecipientNotSelf.selector);
    releaser.setConfig(address(resource), address(0xdead), INITIAL_THRESHOLD, 20);
  }

  /// @dev the base auth still gates the variant's config surface
  function test_revert_setConfig_unauthorized() public {
    vm.prank(alice);
    vm.expectRevert(IResourceManager.Unauthorized.selector);
    releaser.setConfig(address(resource), address(releaser), INITIAL_THRESHOLD, 20);
  }

  /// @dev a threshold change still invalidates pending releases (nonce machinery intact)
  function test_revert_release_configChangeFrontrun() public {
    uint256 pendingNonce = releaser.nonce();

    vm.prank(alice);
    resource.approve(address(releaser), type(uint256).max);

    vm.prank(configSetter);
    releaser.setConfig(address(resource), address(releaser), INITIAL_THRESHOLD * 2, 20);

    vm.prank(alice);
    vm.expectRevert(INonce.InvalidNonce.selector);
    releaser.release(pendingNonce, releaseMockToken, alice);
  }

  /// @dev the L1 destination is partner config: settable by the configSetter or the owner,
  /// and deliberately does NOT bump the nonce (it doesn't change searcher terms)
  function test_setL1ResourceRecipient() public {
    address newWallet = makeAddr("NEW_L1_WALLET");
    uint256 nonceBefore = releaser.nonce();

    vm.expectEmit(true, true, false, true, address(releaser));
    emit OptimismBridgedResourceReleaser.L1ResourceRecipientSet(l1OpsWallet, newWallet);

    vm.prank(configSetter);
    releaser.setL1ResourceRecipient(newWallet);

    assertEq(releaser.l1ResourceRecipient(), newWallet);
    assertEq(releaser.nonce(), nonceBefore); // no bump

    // the next release delivers to the new wallet
    uint256 nonce = releaser.nonce();
    vm.startPrank(alice);
    resource.approve(address(releaser), type(uint256).max);

    vm.expectEmit(true, true, true, true, L2_STANDARD_BRIDGE);
    emit MockL2StandardBridge.Withdrawn(
      address(resource), address(releaser), newWallet, INITIAL_THRESHOLD, 100_000, bytes("")
    );
    releaser.release(nonce, releaseMockToken, alice);
    vm.stopPrank();
  }

  function test_setL1ResourceRecipient_asOwner() public {
    address newWallet = makeAddr("NEW_L1_WALLET");
    releaser.setL1ResourceRecipient(newWallet); // test contract is owner
    assertEq(releaser.l1ResourceRecipient(), newWallet);
  }

  function test_revert_setL1ResourceRecipient_unauthorized() public {
    vm.prank(alice);
    vm.expectRevert(IResourceManager.Unauthorized.selector);
    releaser.setL1ResourceRecipient(alice);
  }

  function test_revert_setL1ResourceRecipient_zero() public {
    vm.prank(configSetter);
    vm.expectRevert(OptimismBridgedResourceReleaser.InvalidL1ResourceRecipient.selector);
    releaser.setL1ResourceRecipient(address(0));
  }

  function test_revert_constructor_zeroL1ResourceRecipient() public {
    vm.expectRevert(OptimismBridgedResourceReleaser.InvalidL1ResourceRecipient.selector);
    new TestOptimismBridgedResourceReleaser(
      address(resource), INITIAL_THRESHOLD, address(tokenJar), address(feeController), address(0)
    );
  }

  /// @dev a canonical burn is just a configuration of this variant: l1ResourceRecipient = 0xdead
  function test_release_burnConfig() public {
    TokenJar burnJar = new TokenJar();
    TestOptimismBridgedResourceReleaser burnReleaser = new TestOptimismBridgedResourceReleaser(
      address(resource), INITIAL_THRESHOLD, address(burnJar), address(feeController), L1_BURN
    );
    burnJar.setReleaser(address(burnReleaser));
    mockToken.mint(address(burnJar), INITIAL_TOKEN_AMOUNT);

    vm.startPrank(alice);
    resource.approve(address(burnReleaser), type(uint256).max);

    vm.expectEmit(true, true, true, true, L2_STANDARD_BRIDGE);
    emit MockL2StandardBridge.Withdrawn(
      address(resource), address(burnReleaser), L1_BURN, INITIAL_THRESHOLD, 100_000, bytes("")
    );
    burnReleaser.release(0, releaseMockToken, alice);
    vm.stopPrank();
  }
}
