// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SBXToken} from "../src/SBXToken.sol";
import {SBXAllocationManager} from "../src/SBXAllocationManager.sol";
import {SBXPresaleVesting} from "../src/SBXPresaleVesting.sol";
import {SBXGovernor, IPresaleVotes} from "../src/SBXGovernor.sol";

contract SBXTest is Test {
    SBXToken token;
    SBXAllocationManager manager;
    SBXPresaleVesting vesting;
    SBXGovernor governor;
    TimelockController timelock;

    address board = makeAddr("board");
    address marketMaker = makeAddr("marketMaker");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    uint256 constant ALICE_ALLOC = 5_000_000 ether;
    uint256 constant BOB_ALLOC = 1_000_000 ether;
    bytes32 aliceLeaf;
    bytes32 bobLeaf;
    bytes32 root;

    uint64 constant YEAR = 365 days;

    function setUp() public {
        vm.warp(1_800_000_000);

        address[] memory none = new address[](0);
        address[] memory anyone = new address[](1); // address(0) = open executor
        timelock = new TimelockController(2 days, none, anyone, address(this));

        manager = new SBXAllocationManager(address(timelock));
        token = new SBXToken(address(manager));

        aliceLeaf = _leaf(alice, ALICE_ALLOC);
        bobLeaf = _leaf(bob, BOB_ALLOC);
        root = _hashPair(aliceLeaf, bobLeaf);
        vesting = new SBXPresaleVesting(token, address(timelock), root, ALICE_ALLOC + BOB_ALLOC, YEAR, YEAR);

        governor =
            new SBXGovernor(token, IPresaleVotes(address(vesting)), timelock, board, 1 days, 7 days, 100_000 ether, 4);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        manager.initialize(token, address(vesting), marketMaker, 50_000_000 ether);
    }

    // ---------------- token / allocation ----------------

    function test_TgeSupply() public view {
        assertEq(token.totalSupply(), 150_000_000 ether);
        assertEq(token.balanceOf(address(vesting)), 100_000_000 ether);
        assertEq(token.balanceOf(marketMaker), 50_000_000 ether);
        assertEq(token.cap(), 1_000_000_000 ether);
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    function test_OnlyManagerMints() public {
        vm.expectRevert(SBXToken.NotMinter.selector);
        token.mint(alice, 1);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(SBXAllocationManager.AlreadyInitialized.selector);
        manager.initialize(token, address(vesting), marketMaker, 0);
    }

    function test_MintOnlyByTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        manager.mint(SBXAllocationManager.Bucket.PublicSaleA, treasury, 1);
    }

    function test_PresaleBucketCannotBeMintedAgain() public {
        vm.prank(address(timelock));
        vm.expectRevert(SBXAllocationManager.BucketMintedAtTge.selector);
        manager.mint(SBXAllocationManager.Bucket.Presale, treasury, 1);
    }

    function test_BucketCaps() public {
        vm.startPrank(address(timelock));
        manager.mint(SBXAllocationManager.Bucket.PublicSaleA, treasury, 100_000_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                SBXAllocationManager.BucketCapExceeded.selector, SBXAllocationManager.Bucket.PublicSaleA, 0
            )
        );
        manager.mint(SBXAllocationManager.Bucket.PublicSaleA, treasury, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                SBXAllocationManager.BucketCapExceeded.selector, SBXAllocationManager.Bucket.MarketMaker, 0
            )
        );
        manager.mint(SBXAllocationManager.Bucket.MarketMaker, treasury, 1);
        vm.stopPrank();
    }

    function test_TreasuryRateLimit() public {
        vm.startPrank(address(timelock));
        manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 20_000_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(SBXAllocationManager.TreasuryEpochLimitExceeded.selector, 5_000_000 ether)
        );
        manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 5_000_001 ether);
        manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 5_000_000 ether);

        vm.warp(block.timestamp + 30 days);
        manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 25_000_000 ether);
        vm.stopPrank();
    }

    function test_FullSupplyNeverExceedsCap() public {
        vm.startPrank(address(timelock));
        manager.mint(SBXAllocationManager.Bucket.PublicSaleA, treasury, 100_000_000 ether);
        manager.mint(SBXAllocationManager.Bucket.PublicSaleB, treasury, 100_000_000 ether);
        for (uint256 i = 0; i < 26; i++) {
            manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 25_000_000 ether);
            vm.warp(block.timestamp + 30 days);
        }
        vm.expectRevert();
        manager.mint(SBXAllocationManager.Bucket.Treasury, treasury, 1);
        vm.stopPrank();
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    // ---------------- vesting ----------------

    function test_RegisterRejectsBadProof() public {
        bytes32[] memory proof = _proof(bobLeaf);
        vm.expectRevert(SBXPresaleVesting.InvalidProof.selector);
        vesting.register(alice, ALICE_ALLOC + 1, proof);
    }

    function test_RegisterOnce() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vm.expectRevert(SBXPresaleVesting.AlreadyRegistered.selector);
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
    }

    function test_NothingReleasableBeforeDaoStart() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vm.warp(block.timestamp + 5 * YEAR);
        assertEq(vesting.releasable(alice), 0);
        vm.expectRevert(SBXPresaleVesting.NothingToRelease.selector);
        vesting.release(alice);
    }

    function test_StartVestingOnlyTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vesting.startVesting(uint64(block.timestamp));
    }

    function test_CliffThenLinear() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        uint64 t0 = uint64(block.timestamp);
        vm.prank(address(timelock));
        vesting.startVesting(t0);

        vm.warp(t0 + YEAR - 1);
        assertEq(vesting.releasable(alice), 0);

        vm.warp(t0 + YEAR + YEAR / 2);
        vesting.release(alice);
        assertEq(token.balanceOf(alice), ALICE_ALLOC / 2);

        vm.warp(t0 + 2 * YEAR);
        vesting.release(alice);
        assertEq(token.balanceOf(alice), ALICE_ALLOC);
        assertEq(vesting.releasable(alice), 0);
    }

    function test_UnallocatedOnlyUnsoldTokens() public {
        uint256 unsold = 100_000_000 ether - ALICE_ALLOC - BOB_ALLOC;
        assertEq(vesting.unallocated(), unsold);

        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(SBXPresaleVesting.ExceedsUnallocated.selector, unsold));
        vesting.burnUnallocated(unsold + 1);

        vesting.burnUnallocated(unsold / 2);
        vesting.withdrawUnallocated(treasury, unsold - unsold / 2);
        vm.stopPrank();

        assertEq(vesting.unallocated(), 0);
        assertEq(token.balanceOf(address(vesting)), ALICE_ALLOC + BOB_ALLOC);
        assertEq(token.totalSupply(), 150_000_000 ether - unsold / 2);
    }

    // ---------------- governance ----------------

    function test_LockedPresaleCountsAsVotes() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vm.warp(block.timestamp + 1);
        assertEq(governor.getVotes(alice, block.timestamp - 1), ALICE_ALLOC);
    }

    function test_ReleasedTokensNotDoubleCounted() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(address(timelock));
        vesting.startVesting(uint64(block.timestamp));

        vm.warp(block.timestamp + YEAR + YEAR / 4);
        vesting.release(alice);
        vm.warp(block.timestamp + 1);
        assertEq(governor.getVotes(alice, block.timestamp - 1), ALICE_ALLOC);
    }

    /// DAO votes to start presale release; Board co-signs; timelock executes.
    function test_DaoAndBoardStartVesting() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vesting.register(bob, BOB_ALLOC, _proof(aliceLeaf));
        vm.warp(block.timestamp + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _proposal(
            address(vesting), abi.encodeCall(SBXPresaleVesting.startVesting, (uint64(block.timestamp + 10 days)))
        );
        uint256 id = _proposeAndPass(alice, t, v, c, d);

        vm.prank(board);
        governor.approveProposal(id);
        governor.queue(t, v, c, keccak256(bytes(d)));
        vm.warp(block.timestamp + 2 days + 1);
        governor.execute(t, v, c, keccak256(bytes(d)));

        assertEq(vesting.start(), block.timestamp); // proposed date had passed -> starts at execution

        vm.prank(address(timelock));
        vm.expectRevert(SBXPresaleVesting.AlreadyStarted.selector);
        vesting.startVesting(uint64(block.timestamp + 1));
    }

    function test_QueueRequiresBoard() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vesting.register(bob, BOB_ALLOC, _proof(aliceLeaf));
        vm.warp(block.timestamp + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _proposal(
            address(manager),
            abi.encodeCall(SBXAllocationManager.mint, (SBXAllocationManager.Bucket.PublicSaleA, treasury, 1 ether))
        );
        uint256 id = _proposeAndPass(alice, t, v, c, d);

        vm.expectRevert(abi.encodeWithSelector(SBXGovernor.BoardApprovalRequired.selector, id));
        governor.queue(t, v, c, keccak256(bytes(d)));
    }

    function test_OnlyBoardApproves() public {
        vesting.register(alice, ALICE_ALLOC, _proof(bobLeaf));
        vm.warp(block.timestamp + 1);
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _proposal(
            address(vesting), abi.encodeCall(SBXPresaleVesting.startVesting, (uint64(block.timestamp + 10 days)))
        );
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, d);

        vm.prank(alice);
        vm.expectRevert(SBXGovernor.NotBoard.selector);
        governor.approveProposal(id);
    }

    // ---------------- helpers ----------------

    function _proposeAndPass(address voter, address[] memory t, uint256[] memory v, bytes[] memory c, string memory d)
        internal
        returns (uint256 id)
    {
        vm.prank(voter);
        id = governor.propose(t, v, c, d);
        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.prank(voter);
        governor.castVote(id, 1);
        if (governor.getVotes(bob, governor.proposalSnapshot(id)) > 0) {
            vm.prank(bob);
            governor.castVote(id, 1);
        }
        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function _proposal(address target, bytes memory data)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = target;
        c[0] = data;
        d = "proposal";
    }

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }
}
