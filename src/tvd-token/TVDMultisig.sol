// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  TVDMultisig
 * @notice M-of-N multisignature wallet
 *
 * ── Usage ────────────────────────────────────────────────────────────
 *  1. Any owner calls submitTransaction(to, value, data) to propose an action.
 *  2. Owners (including the proposer) call confirmTransaction(txId).
 *  3. Once `required` confirmations are reached, any owner calls
 *     executeTransaction(txId) to dispatch the call.
 *  4. Before execution, a confirming owner may call revokeConfirmation(txId).
 *
 * ── Ownership management ─────────────────────────────────────────────
 *  Adding / removing owners or changing the threshold must itself go
 *  through the multisig (submit + confirm + execute), preserving the
 *  M-of-N security invariant at all times.
 */
contract TVDMultisig {
    // ──────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────

    event Deposit(address indexed sender, uint256 value);
    event SubmitTransaction(address indexed owner, uint256 indexed txId, address indexed to, uint256 value, bytes data);
    event ConfirmTransaction(address indexed owner, uint256 indexed txId);
    event RevokeConfirmation(address indexed owner, uint256 indexed txId);
    event ExecuteTransaction(address indexed owner, uint256 indexed txId);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);

    // ──────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;

    /// @notice Minimum confirmations required to execute a transaction.
    uint256 public required;

    Transaction[] public transactions;

    /// @notice confirmations[txId][owner] = true if owner confirmed.
    mapping(uint256 => mapping(address => bool)) public confirmations;

    // ──────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────

    modifier onlyWallet() {
        require(msg.sender == address(this), "Multisig: caller is not the wallet");
        _;
    }

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Multisig: caller is not an owner");
        _;
    }

    modifier txExists(uint256 txId) {
        require(txId < transactions.length, "Multisig: tx does not exist");
        _;
    }

    modifier notExecuted(uint256 txId) {
        require(!transactions[txId].executed, "Multisig: tx already executed");
        _;
    }

    modifier notConfirmed(uint256 txId) {
        require(!confirmations[txId][msg.sender], "Multisig: tx already confirmed");
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    /**
     * @param _owners   Initial set of owner addresses (no duplicates, no zero address).
     * @param _required Number of confirmations required (1 ≤ required ≤ owners.length).
     */
    constructor(address[] memory _owners, uint256 _required) {
        require(_owners.length > 0, "Multisig: owners required");
        require(_required > 0 && _required <= _owners.length, "Multisig: invalid required count");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Multisig: invalid owner");
            require(!isOwner[owner], "Multisig: duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }

        required = _required;
        emit RequirementChanged(_required);
    }

    // ──────────────────────────────────────────────────────────────────
    // Receive ETH
    // ──────────────────────────────────────────────────────────────────

    receive() external payable {
        if (msg.value > 0) emit Deposit(msg.sender, msg.value);
    }

    // ──────────────────────────────────────────────────────────────────
    // Owner actions
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Propose a transaction for multisig approval.
     *         Auto-confirms on behalf of the submitter.
     *
     * @param to    Target address (contract or EOA).
     * @param value ETH to forward (0 for contract calls with no ETH).
     * @param data  ABI-encoded calldata (use abi.encodeWithSignature / encodeWithSelector).
     * @return txId Index of the newly created transaction.
     */
    function submitTransaction(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        require(to != address(0), "Multisig: invalid target");

        txId = transactions.length;
        transactions.push(Transaction({to: to, value: value, data: data, executed: false}));

        emit SubmitTransaction(msg.sender, txId, to, value, data);

        // Auto-confirm from the submitter
        _confirm(txId);
    }

    /**
     * @notice Confirm a pending transaction.
     * @param txId Transaction index.
     */
    function confirmTransaction(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) notConfirmed(txId) {
        _confirm(txId);
    }

    /**
     * @notice Revoke a previously given confirmation (only before execution).
     * @param txId Transaction index.
     */
    function revokeConfirmation(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        require(confirmations[txId][msg.sender], "Multisig: not confirmed");
        confirmations[txId][msg.sender] = false;
        emit RevokeConfirmation(msg.sender, txId);
    }

    /**
     * @notice Execute a transaction once the required confirmations are met.
     * @param txId Transaction index.
     */
    function executeTransaction(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        require(getConfirmationCount(txId) >= required, "Multisig: not enough confirmations");

        Transaction storage txn = transactions[txId];
        txn.executed = true;

        (bool success, bytes memory returnData) = txn.to.call{value: txn.value}(txn.data);
        if (!success) {
            // Bubble up the revert reason
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert("Multisig: execution failed");
        }

        emit ExecuteTransaction(msg.sender, txId);
    }

    // ──────────────────────────────────────────────────────────────────
    // Self-governed owner management (must go through the multisig)
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Add a new owner. Must be called via executeTransaction (onlyWallet).
     * @param owner New owner address.
     */
    function addOwner(address owner) external onlyWallet {
        require(owner != address(0), "Multisig: invalid owner");
        require(!isOwner[owner], "Multisig: already an owner");

        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }

    /**
     * @notice Remove an existing owner. Must be called via executeTransaction.
     *         Automatically lowers `required` if it would exceed the new owner count.
     *
     * @param owner Owner address to remove.
     */
    function removeOwner(address owner) external onlyWallet {
        require(isOwner[owner], "Multisig: not an owner");
        require(owners.length > 1, "Multisig: cannot remove last owner");

        isOwner[owner] = false;

        // Remove from array
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        // Clamp required if needed
        if (required > owners.length) {
            required = owners.length;
            emit RequirementChanged(required);
        }

        emit OwnerRemoved(owner);
    }

    /**
     * @notice Change the confirmation threshold. Must be called via executeTransaction.
     * @param _required New threshold (1 ≤ _required ≤ owners.length).
     */
    function changeRequirement(uint256 _required) external onlyWallet {
        require(_required > 0 && _required <= owners.length, "Multisig: invalid required count");
        required = _required;
        emit RequirementChanged(_required);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    /// @notice Returns the list of current owners.
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Total number of submitted transactions.
    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }

    /**
     * @notice Returns full details of a transaction.
     * @param txId Transaction index.
     */
    function getTransaction(uint256 txId)
        external
        view
        txExists(txId)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 confirmationCount)
    {
        Transaction storage txn = transactions[txId];
        return (txn.to, txn.value, txn.data, txn.executed, getConfirmationCount(txId));
    }

    /**
     * @notice Number of confirmations a transaction has received.
     * @param txId Transaction index.
     */
    function getConfirmationCount(uint256 txId) public view returns (uint256 count) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmations[txId][owners[i]]) count++;
        }
    }

    /**
     * @notice Returns the addresses that have confirmed a transaction.
     * @param txId Transaction index.
     */
    function getConfirmations(uint256 txId) external view returns (address[] memory confirmed) {
        address[] memory temp = new address[](owners.length);
        uint256 count;
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmations[txId][owners[i]]) {
                temp[count] = owners[i];
                count++;
            }
        }
        confirmed = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            confirmed[i] = temp[i];
        }
    }

    /**
     * @notice Returns pending transaction IDs (submitted but not yet executed).
     */
    function getPendingTransactions() external view returns (uint256[] memory) {
        return _filterTransactions(false);
    }

    /**
     * @notice Returns executed transaction IDs.
     */
    function getExecutedTransactions() external view returns (uint256[] memory) {
        return _filterTransactions(true);
    }

    // ──────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────

    function _confirm(uint256 txId) internal {
        confirmations[txId][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, txId);
    }

    function _filterTransactions(bool executed) internal view returns (uint256[] memory result) {
        uint256 total = transactions.length;
        uint256 count;
        for (uint256 i = 0; i < total; i++) {
            if (transactions[i].executed == executed) count++;
        }
        result = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < total; i++) {
            if (transactions[i].executed == executed) {
                result[idx++] = i;
            }
        }
    }
}
