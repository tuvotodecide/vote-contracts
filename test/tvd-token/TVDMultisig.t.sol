// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDMultisig} from "../../src/tvd-token/TVDMultisig.sol";

/// @dev Simple target contract used to verify multisig calls.
contract MockTarget {
    uint256 public value;
    event Called(uint256 newValue);

    function setValue(uint256 _value) external {
        value = _value;
        emit Called(_value);
    }

    function revertAlways() external pure {
        revert("MockTarget: always reverts");
    }

    receive() external payable {}
}

contract TVDMultisigTest is Test {
    TVDMultisig public multisig;
    MockTarget  public target;

    address public owner1   = makeAddr("owner1");
    address public owner2   = makeAddr("owner2");
    address public owner3   = makeAddr("owner3");
    address public stranger = makeAddr("stranger");
    address public newOwner = makeAddr("newOwner");

    // ──────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────

    function _owners() internal view returns (address[] memory o) {
        o = new address[](3);
        o[0] = owner1; o[1] = owner2; o[2] = owner3;
    }

    /// Submit from owner1 and collect second confirmation from owner2 (2-of-3).
    function _submitAndConfirm(bytes memory data) internal returns (uint256 txId) {
        vm.prank(owner1);
        txId = multisig.submitTransaction(address(target), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);
    }

    function setUp() public {
        multisig = new TVDMultisig(_owners(), 2);
        target   = new MockTarget();
        vm.deal(address(multisig), 10 ether);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsOwners() public view {
        assertTrue(multisig.isOwner(owner1));
        assertTrue(multisig.isOwner(owner2));
        assertTrue(multisig.isOwner(owner3));
    }

    function test_constructor_setsRequired() public view {
        assertEq(multisig.required(), 2);
    }

    function test_constructor_ownersArray() public view {
        address[] memory owners = multisig.getOwners();
        assertEq(owners.length, 3);
    }

    function test_constructor_revertsNoOwners() public {
        address[] memory empty;
        vm.expectRevert("Multisig: owners required");
        new TVDMultisig(empty, 1);
    }

    function test_constructor_revertsRequiredZero() public {
        vm.expectRevert("Multisig: invalid required count");
        new TVDMultisig(_owners(), 0);
    }

    function test_constructor_revertsRequiredExceedsOwners() public {
        vm.expectRevert("Multisig: invalid required count");
        new TVDMultisig(_owners(), 4);
    }

    function test_constructor_revertsZeroAddressOwner() public {
        address[] memory o = new address[](2);
        o[0] = owner1; o[1] = address(0);
        vm.expectRevert("Multisig: invalid owner");
        new TVDMultisig(o, 1);
    }

    function test_constructor_revertsDuplicateOwner() public {
        address[] memory o = new address[](2);
        o[0] = owner1; o[1] = owner1;
        vm.expectRevert("Multisig: duplicate owner");
        new TVDMultisig(o, 1);
    }

    // ──────────────────────────────────────────────────────────────────
    // Receive ETH
    // ──────────────────────────────────────────────────────────────────

    function test_receive_acceptsEth() public {
        uint256 before = address(multisig).balance;
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(multisig).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(multisig).balance, before + 1 ether);
    }

    // ──────────────────────────────────────────────────────────────────
    // submitTransaction
    // ──────────────────────────────────────────────────────────────────

    function test_submit_createsTransaction() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);
        assertEq(txId, 0);
        assertEq(multisig.transactionCount(), 1);
    }

    function test_submit_autoConfirmsForSubmitter() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);
        assertTrue(multisig.confirmations(txId, owner1));
        assertEq(multisig.getConfirmationCount(txId), 1);
    }

    function test_submit_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Multisig: caller is not an owner");
        multisig.submitTransaction(address(target), 0, "");
    }

    function test_submit_revertsZeroTarget() public {
        vm.prank(owner1);
        vm.expectRevert("Multisig: invalid target");
        multisig.submitTransaction(address(0), 0, "");
    }

    function test_submit_emitsEvent() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (7));
        vm.expectEmit(true, true, true, false);
        emit TVDMultisig.SubmitTransaction(owner1, 0, address(target), 0, data);
        vm.prank(owner1);
        multisig.submitTransaction(address(target), 0, data);
    }

    // ──────────────────────────────────────────────────────────────────
    // confirmTransaction
    // ──────────────────────────────────────────────────────────────────

    function test_confirm_incrementsCount() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(owner2);
        multisig.confirmTransaction(txId);
        assertEq(multisig.getConfirmationCount(txId), 2);
    }

    function test_confirm_emitsEvent() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.expectEmit(true, true, false, false);
        emit TVDMultisig.ConfirmTransaction(owner2, txId);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);
    }

    function test_confirm_revertsNonOwner() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(stranger);
        vm.expectRevert("Multisig: caller is not an owner");
        multisig.confirmTransaction(txId);
    }

    function test_confirm_revertsAlreadyConfirmed() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(owner1);
        vm.expectRevert("Multisig: tx already confirmed");
        multisig.confirmTransaction(txId);
    }

    function test_confirm_revertsNonExistentTx() public {
        vm.prank(owner1);
        vm.expectRevert("Multisig: tx does not exist");
        multisig.confirmTransaction(99);
    }

    // ──────────────────────────────────────────────────────────────────
    // revokeConfirmation
    // ──────────────────────────────────────────────────────────────────

    function test_revoke_removesConfirmation() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(owner1);
        multisig.revokeConfirmation(txId);

        assertFalse(multisig.confirmations(txId, owner1));
        assertEq(multisig.getConfirmationCount(txId), 0);
    }

    function test_revoke_emitsEvent() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.expectEmit(true, true, false, false);
        emit TVDMultisig.RevokeConfirmation(owner1, txId);
        vm.prank(owner1);
        multisig.revokeConfirmation(txId);
    }

    function test_revoke_revertsNotConfirmed() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(owner2); // owner2 hasn't confirmed yet
        vm.expectRevert("Multisig: not confirmed");
        multisig.revokeConfirmation(txId);
    }

    function test_revoke_revertsNonOwner() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        vm.prank(stranger);
        vm.expectRevert("Multisig: caller is not an owner");
        multisig.revokeConfirmation(txId);
    }

    // ──────────────────────────────────────────────────────────────────
    // executeTransaction
    // ──────────────────────────────────────────────────────────────────

    function test_execute_callsTarget() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (99));
        uint256 txId = _submitAndConfirm(data);

        vm.prank(owner1);
        multisig.executeTransaction(txId);

        assertEq(target.value(), 99);
    }

    function test_execute_marksExecuted() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        uint256 txId = _submitAndConfirm(data);

        vm.prank(owner1);
        multisig.executeTransaction(txId);

        (,,, bool executed,) = multisig.getTransaction(txId);
        assertTrue(executed);
    }

    function test_execute_emitsEvent() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        uint256 txId = _submitAndConfirm(data);

        vm.expectEmit(true, true, false, false);
        emit TVDMultisig.ExecuteTransaction(owner3, txId);
        vm.prank(owner3);
        multisig.executeTransaction(txId);
    }

    function test_execute_revertsNotEnoughConfirmations() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);
        // Only 1 confirmation, need 2

        vm.prank(owner1);
        vm.expectRevert("Multisig: not enough confirmations");
        multisig.executeTransaction(txId);
    }

    function test_execute_revertsAlreadyExecuted() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        uint256 txId = _submitAndConfirm(data);

        vm.prank(owner1);
        multisig.executeTransaction(txId);

        vm.prank(owner2);
        vm.expectRevert("Multisig: tx already executed");
        multisig.executeTransaction(txId);
    }

    function test_execute_revertsNonOwner() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        uint256 txId = _submitAndConfirm(data);

        vm.prank(stranger);
        vm.expectRevert("Multisig: caller is not an owner");
        multisig.executeTransaction(txId);
    }

    function test_execute_bubblesUpRevertReason() public {
        bytes memory data = abi.encodeCall(MockTarget.revertAlways, ());
        uint256 txId = _submitAndConfirm(data);

        vm.prank(owner1);
        vm.expectRevert("MockTarget: always reverts");
        multisig.executeTransaction(txId);
    }

    function test_execute_forwardsEth() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 sendAmount = 1 ether;

        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(recipient, sendAmount, "");
        vm.prank(owner2);
        multisig.confirmTransaction(txId);

        uint256 before = recipient.balance;
        vm.prank(owner1);
        multisig.executeTransaction(txId);

        assertEq(recipient.balance, before + sendAmount);
    }

    // ──────────────────────────────────────────────────────────────────
    // addOwner (via multisig)
    // ──────────────────────────────────────────────────────────────────

    function test_addOwner_viaMultisig() public {
        bytes memory data = abi.encodeCall(TVDMultisig.addOwner, (newOwner));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);
        vm.prank(owner1);
        multisig.executeTransaction(txId);

        assertTrue(multisig.isOwner(newOwner));
        assertEq(multisig.getOwners().length, 4);
    }

    function test_addOwner_revertsDirectCall() public {
        vm.prank(owner1);
        vm.expectRevert("Multisig: caller is not the wallet");
        multisig.addOwner(newOwner);
    }

    function test_addOwner_revertsDuplicate() public {
        bytes memory data = abi.encodeCall(TVDMultisig.addOwner, (owner1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);

        vm.prank(owner1);
        vm.expectRevert("Multisig: already an owner");
        multisig.executeTransaction(txId);
    }

    // ──────────────────────────────────────────────────────────────────
    // removeOwner (via multisig)
    // ──────────────────────────────────────────────────────────────────

    function test_removeOwner_viaMultisig() public {
        bytes memory data = abi.encodeCall(TVDMultisig.removeOwner, (owner3));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);
        vm.prank(owner1);
        multisig.executeTransaction(txId);

        assertFalse(multisig.isOwner(owner3));
        assertEq(multisig.getOwners().length, 2);
    }

    function test_removeOwner_clampsRequired() public {
        // Deploy a 2-of-2 multisig, then remove one owner → required must drop to 1
        address[] memory two = new address[](2);
        two[0] = owner1; two[1] = owner2;
        TVDMultisig ms = new TVDMultisig(two, 2);

        bytes memory data = abi.encodeCall(TVDMultisig.removeOwner, (owner2));
        vm.prank(owner1);
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.prank(owner1);
        ms.executeTransaction(txId);

        assertEq(ms.required(), 1);
        assertEq(ms.getOwners().length, 1);
    }

    function test_removeOwner_revertsLastOwner() public {
        address[] memory one = new address[](1);
        one[0] = owner1;
        TVDMultisig ms = new TVDMultisig(one, 1);

        bytes memory data = abi.encodeCall(TVDMultisig.removeOwner, (owner1));
        vm.prank(owner1);
        uint256 txId = ms.submitTransaction(address(ms), 0, data);

        vm.prank(owner1);
        vm.expectRevert("Multisig: cannot remove last owner");
        ms.executeTransaction(txId);
    }

    function test_removeOwner_revertsDirectCall() public {
        vm.prank(owner1);
        vm.expectRevert("Multisig: caller is not the wallet");
        multisig.removeOwner(owner2);
    }

    // ──────────────────────────────────────────────────────────────────
    // changeRequirement (via multisig)
    // ──────────────────────────────────────────────────────────────────

    function test_changeRequirement_viaMultisig() public {
        bytes memory data = abi.encodeCall(TVDMultisig.changeRequirement, (3));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);
        vm.prank(owner1);
        multisig.executeTransaction(txId);

        assertEq(multisig.required(), 3);
    }

    function test_changeRequirement_revertsZero() public {
        bytes memory data = abi.encodeCall(TVDMultisig.changeRequirement, (0));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);

        vm.prank(owner1);
        vm.expectRevert("Multisig: invalid required count");
        multisig.executeTransaction(txId);
    }

    function test_changeRequirement_revertsExceedsOwners() public {
        bytes memory data = abi.encodeCall(TVDMultisig.changeRequirement, (4));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);

        vm.prank(owner1);
        vm.expectRevert("Multisig: invalid required count");
        multisig.executeTransaction(txId);
    }

    function test_changeRequirement_revertsDirectCall() public {
        vm.prank(owner1);
        vm.expectRevert("Multisig: caller is not the wallet");
        multisig.changeRequirement(1);
    }

    // ──────────────────────────────────────────────────────────────────
    // View helpers
    // ──────────────────────────────────────────────────────────────────

    function test_getConfirmations_returnsConfirmers() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);
        vm.prank(owner2);
        multisig.confirmTransaction(txId);

        address[] memory confirmed = multisig.getConfirmations(txId);
        assertEq(confirmed.length, 2);
    }

    function test_getPendingTransactions() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        vm.prank(owner1);
        multisig.submitTransaction(address(target), 0, data);
        vm.prank(owner1);
        multisig.submitTransaction(address(target), 0, data);

        uint256[] memory pending = multisig.getPendingTransactions();
        assertEq(pending.length, 2);
    }

    function test_getExecutedTransactions() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (1));
        uint256 txId = _submitAndConfirm(data);

        vm.prank(owner1);
        multisig.executeTransaction(txId);

        uint256[] memory executed = multisig.getExecutedTransactions();
        assertEq(executed.length, 1);
        assertEq(executed[0], txId);
    }

    function test_getTransaction_returnsCorrectData() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (55));
        vm.prank(owner1);
        uint256 txId = multisig.submitTransaction(address(target), 0, data);

        (address to, uint256 val,, bool executed, uint256 count) =
            multisig.getTransaction(txId);

        assertEq(to, address(target));
        assertEq(val, 0);
        assertFalse(executed);
        assertEq(count, 1);
    }
}
