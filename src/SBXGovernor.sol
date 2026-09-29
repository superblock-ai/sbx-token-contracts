// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IPresaleVotes {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
}

/// @title SBX DAO Governor
/// @notice Token-holder governance with a Board co-signature:
///         1. Holders vote (SBX balance + locked presale allocation).
///         2. A passed proposal must also be approved by the Board multisig before it can be queued.
///         3. It then waits in the timelock before execution.
///         This implements "with DAO and Board approval" from the tokenomics.
contract SBXGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    IPresaleVotes public immutable presaleVesting;

    address public board;
    mapping(uint256 proposalId => bool) public boardApproved;

    event BoardChanged(address indexed previousBoard, address indexed newBoard);
    event BoardApproved(uint256 indexed proposalId);

    error NotBoard();
    error BoardApprovalRequired(uint256 proposalId);
    error ProposalNotApprovable(uint256 proposalId, ProposalState state);

    constructor(
        IVotes token_,
        IPresaleVotes presaleVesting_,
        TimelockController timelock_,
        address board_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumPercent_
    )
        Governor("SBX DAO")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumPercent_)
        GovernorTimelockControl(timelock_)
    {
        presaleVesting = presaleVesting_;
        _setBoard(board_);
    }

    // ---- Board ----

    /// @notice Board co-signs a proposal. Allowed while pending, active or succeeded.
    function approveProposal(uint256 proposalId) external {
        if (msg.sender != board) revert NotBoard();
        ProposalState s = state(proposalId);
        if (s != ProposalState.Pending && s != ProposalState.Active && s != ProposalState.Succeeded) {
            revert ProposalNotApprovable(proposalId, s);
        }
        boardApproved[proposalId] = true;
        emit BoardApproved(proposalId);
    }

    /// @notice Replace the Board. Only via a passed (and Board-approved) proposal.
    function setBoard(address newBoard) external onlyGovernance {
        _setBoard(newBoard);
    }

    function _setBoard(address newBoard) private {
        emit BoardChanged(board, newBoard);
        board = newBoard;
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        if (!boardApproved[proposalId]) revert BoardApprovalRequired(proposalId);
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    // ---- Voting power: liquid SBX + locked presale allocation ----

    function _getVotes(address account, uint256 timepoint, bytes memory params)
        internal
        view
        override(Governor, GovernorVotes)
        returns (uint256)
    {
        return super._getVotes(account, timepoint, params) + presaleVesting.getPastVotes(account, timepoint);
    }

    // ---- Required overrides ----

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
