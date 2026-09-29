// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SBXToken} from "./SBXToken.sol";

/// @title SBX presale vesting
/// @notice Holds the 100M SBX presale allocation and releases it to buyers:
///         nothing until the DAO starts vesting, then a 12-month cliff, then linear release over 12 months.
///
///         Buyer allocations come from the presale database as a Merkle tree of (account, amount).
///         A buyer (or anyone on their behalf) calls {register} once with a proof. Registered, unreleased
///         tokens count as voting power in {SBXGovernor}, so presale buyers can vote on the release
///         itself while their tokens are still locked.
///
///         Tokens beyond the registered-or-registrable allocations (unsold presale) can only be moved or
///         burned by the DAO timelock, matching "the community will vote on whether to retain or
///         permanently burn any unsold tokens".
contract SBXPresaleVesting is Ownable {
    using Checkpoints for Checkpoints.Trace208;

    SBXToken public immutable token;
    bytes32 public immutable merkleRoot;
    /// @notice Sum of every allocation in the Merkle tree.
    uint256 public immutable totalAllocated;
    uint64 public immutable cliff;
    uint64 public immutable duration;

    /// @notice Vesting start, set by DAO vote. Zero until then.
    uint64 public start;

    mapping(address account => uint256) public allocation;
    mapping(address account => uint256) public released;
    uint256 public totalReleased;

    mapping(address account => Checkpoints.Trace208) private _votes;

    event Registered(address indexed account, uint256 allocation);
    event VestingStarted(uint64 start);
    event Released(address indexed account, uint256 amount);
    event UnallocatedWithdrawn(address indexed to, uint256 amount);
    event UnallocatedBurned(uint256 amount);

    error AlreadyRegistered();
    error InvalidProof();
    error AlreadyStarted();
    error NothingToRelease();
    error ExceedsUnallocated(uint256 available);
    error FutureLookup(uint256 timepoint, uint48 clock);
    error ZeroAddress();

    constructor(
        SBXToken token_,
        address timelock,
        bytes32 merkleRoot_,
        uint256 totalAllocated_,
        uint64 cliff_,
        uint64 duration_
    ) Ownable(timelock) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        merkleRoot = merkleRoot_;
        totalAllocated = totalAllocated_;
        cliff = cliff_;
        duration = duration_;
    }

    // ---- buyers ----

    /// @notice Record `account`'s presale allocation. Idempotent per account; anyone may call.
    function register(address account, uint256 amount, bytes32[] calldata proof) external {
        if (allocation[account] != 0) revert AlreadyRegistered();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (amount == 0 || !MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();

        allocation[account] = amount;
        _writeVotes(account, amount);
        emit Registered(account, amount);
    }

    /// @notice Send `account` everything vested so far. Anyone may call.
    function release(address account) external returns (uint256 amount) {
        amount = releasable(account);
        if (amount == 0) revert NothingToRelease();

        released[account] += amount;
        totalReleased += amount;
        _writeVotes(account, allocation[account] - released[account]);

        token.transfer(account, amount);
        emit Released(account, amount);
    }

    function vestedAmount(address account, uint64 timestamp) public view returns (uint256) {
        uint256 total = allocation[account];
        if (start == 0) return 0;
        uint64 cliffEnd = start + cliff;
        if (timestamp < cliffEnd) return 0;
        if (timestamp >= cliffEnd + duration) return total;
        return (total * (timestamp - cliffEnd)) / duration;
    }

    function releasable(address account) public view returns (uint256) {
        return vestedAmount(account, uint64(block.timestamp)) - released[account];
    }

    // ---- DAO ----

    /// @notice Start the vesting clock. DAO + Board only. A future `startTime` schedules it; a time that
    ///         has already passed by execution (proposals take ~10 days) starts it immediately.
    function startVesting(uint64 startTime) external onlyOwner {
        if (start != 0) revert AlreadyStarted();
        if (startTime < block.timestamp) startTime = uint64(block.timestamp);
        start = startTime;
        emit VestingStarted(startTime);
    }

    /// @notice Presale tokens not owed to any buyer (100M minus the Merkle total).
    function unallocated() public view returns (uint256) {
        uint256 owed = totalAllocated - totalReleased;
        uint256 balance = token.balanceOf(address(this));
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Move unsold presale tokens, e.g. back to the treasury.
    function withdrawUnallocated(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _checkUnallocated(amount);
        token.transfer(to, amount);
        emit UnallocatedWithdrawn(to, amount);
    }

    /// @notice Permanently burn unsold presale tokens.
    function burnUnallocated(uint256 amount) external onlyOwner {
        _checkUnallocated(amount);
        token.burn(amount);
        emit UnallocatedBurned(amount);
    }

    // ---- voting power (read by SBXGovernor) ----

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function getVotes(address account) external view returns (uint256) {
        return _votes[account].latest();
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        uint48 now_ = clock();
        if (timepoint >= now_) revert FutureLookup(timepoint, now_);
        return _votes[account].upperLookupRecent(SafeCast.toUint48(timepoint));
    }

    function _writeVotes(address account, uint256 amount) private {
        _votes[account].push(clock(), SafeCast.toUint208(amount));
    }

    function _checkUnallocated(uint256 amount) private view {
        uint256 available = unallocated();
        if (amount > available) revert ExceedsUnallocated(available);
    }
}
