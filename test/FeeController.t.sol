// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {FeeController, IFeeController} from "../src/FeeController.sol";

contract FeeControllerTest is Test {
  FeeController public feeController;

  address public owner;
  address public feeRecipient;
  address public unauthorizedUser;

  function setUp() public {
    owner = makeAddr("owner");
    feeRecipient = makeAddr("feeRecipient");
    unauthorizedUser = makeAddr("unauthorizedUser");

    // The initial owner is a constructor arg (msg.sender would be the CREATE2 deployer proxy
    // in production); the recipient is set post-deploy.
    feeController = new FeeController(owner);
    vm.prank(owner);
    feeController.setFeeRecipient(feeRecipient);
  }

  /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
  //////////////////////////////////////////////////////////////*/

  function test_constructor_ownerArg_unconfigured() public {
    // the owner comes from the constructor arg, NOT msg.sender (which would be the CREATE2
    // deployer proxy in production)
    FeeController fresh = new FeeController(owner);

    assertEq(fresh.owner(), owner);
    assertEq(fresh.feeRecipient(), address(0)); // recipient unset until configured
    assertEq(fresh.feeBps(), 0); // starts at 0 bps
    assertEq(fresh.MAX_FEE_BPS(), 1000);
  }

  function test_revert_constructor_zeroOwner() public {
    vm.expectRevert(IFeeController.InvalidOwner.selector);
    new FeeController(address(0));
  }

  function test_constructor_initialState() public view {
    assertEq(feeController.owner(), owner);
    assertEq(feeController.feeRecipient(), feeRecipient);
    assertEq(feeController.feeBps(), 0); // starts at 0 bps
    assertEq(feeController.MAX_FEE_BPS(), 1000);
  }

  /*//////////////////////////////////////////////////////////////
                              setFeeBps
  //////////////////////////////////////////////////////////////*/

  function test_setFeeBps() public {
    vm.expectEmit(false, false, false, true, address(feeController));
    emit IFeeController.FeeBpsSet(0, 250);

    vm.prank(owner);
    feeController.setFeeBps(250);

    assertEq(feeController.feeBps(), 250);
  }

  function test_setFeeBps_AtCap() public {
    uint256 cap = feeController.MAX_FEE_BPS();
    vm.prank(owner);
    feeController.setFeeBps(cap);
    assertEq(feeController.feeBps(), cap);
  }

  function test_setFeeBps_RevertsAboveCap() public {
    uint256 maxBps = feeController.MAX_FEE_BPS();
    uint256 aboveCap = maxBps + 1;
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IFeeController.FeeTooHigh.selector, aboveCap, maxBps));
    feeController.setFeeBps(aboveCap);

    assertEq(feeController.feeBps(), 0);
  }

  function test_setFeeBps_Unauthorized() public {
    vm.prank(unauthorizedUser);
    vm.expectRevert("UNAUTHORIZED");
    feeController.setFeeBps(250);

    assertEq(feeController.feeBps(), 0);
  }

  function test_setFeeBps_RevertsWhenRecipientUnset() public {
    // Fresh controller with no recipient configured yet
    FeeController fresh = new FeeController(owner);

    // Enabling a non-zero fee with no recipient reverts
    vm.prank(owner);
    vm.expectRevert(IFeeController.InvalidFeeRecipient.selector);
    fresh.setFeeBps(250);

    // Setting it to zero is still allowed
    vm.prank(owner);
    fresh.setFeeBps(0);
    assertEq(fresh.feeBps(), 0);
  }

  /*//////////////////////////////////////////////////////////////
                           setFeeRecipient
  //////////////////////////////////////////////////////////////*/

  function test_setFeeRecipient() public {
    address newRecipient = makeAddr("newRecipient");

    vm.expectEmit(true, true, false, true, address(feeController));
    emit IFeeController.FeeRecipientSet(feeRecipient, newRecipient);

    vm.prank(owner);
    feeController.setFeeRecipient(newRecipient);

    assertEq(feeController.feeRecipient(), newRecipient);
  }

  function test_setFeeRecipient_RevertsOnZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IFeeController.InvalidFeeRecipient.selector);
    feeController.setFeeRecipient(address(0));

    assertEq(feeController.feeRecipient(), feeRecipient);
  }

  function test_setFeeRecipient_Unauthorized() public {
    address newRecipient = makeAddr("newRecipient");
    vm.prank(unauthorizedUser);
    vm.expectRevert("UNAUTHORIZED");
    feeController.setFeeRecipient(newRecipient);

    assertEq(feeController.feeRecipient(), feeRecipient);
  }

  /*//////////////////////////////////////////////////////////////
                              feeConfig
  //////////////////////////////////////////////////////////////*/

  function test_feeConfig_ReturnsBothAtomically() public {
    address newRecipient = makeAddr("newRecipient");
    vm.startPrank(owner);
    feeController.setFeeBps(750);
    feeController.setFeeRecipient(newRecipient);
    vm.stopPrank();

    (uint256 bps, address recipient) = feeController.feeConfig();
    assertEq(bps, 750);
    assertEq(recipient, newRecipient);
  }

  /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
  //////////////////////////////////////////////////////////////*/

  function testFuzz_setFeeBps_WithinCap(uint256 newFeeBps) public {
    newFeeBps = bound(newFeeBps, 0, feeController.MAX_FEE_BPS());
    vm.prank(owner);
    feeController.setFeeBps(newFeeBps);
    assertEq(feeController.feeBps(), newFeeBps);
  }

  function testFuzz_setFeeBps_AboveCapReverts(uint256 newFeeBps) public {
    uint256 maxBps = feeController.MAX_FEE_BPS();
    newFeeBps = bound(newFeeBps, maxBps + 1, type(uint256).max);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(IFeeController.FeeTooHigh.selector, newFeeBps, maxBps));
    feeController.setFeeBps(newFeeBps);
  }
}
