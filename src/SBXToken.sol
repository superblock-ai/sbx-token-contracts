// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title Superblock (SBX)
/// @notice Canonical SBX token on Ethereum. Hard cap of 1,000,000,000 SBX.
/// @dev No supply exists at deploy. The only minter is {SBXAllocationManager}, which enforces the
///      tokenomics buckets and is itself controlled by the DAO timelock. The minter is fixed at deploy
///      and cannot be changed. Vote checkpoints use timestamps (ERC-6372 "mode=timestamp") so that the
///      Governor, vesting and bridge deployments share one clock.
contract SBXToken is ERC20, ERC20Burnable, ERC20Capped, ERC20Permit, ERC20Votes {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    address public immutable minter;

    error NotMinter();
    error ZeroAddress();

    constructor(address minter_) ERC20("Superblock", "SBX") ERC20Capped(MAX_SUPPLY) ERC20Permit("Superblock") {
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }

    // ---- ERC-6372 clock: timestamps ----

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ---- overrides ----

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
