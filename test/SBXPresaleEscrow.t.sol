// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SBXPresaleEscrow} from "../src/SBXPresaleEscrow.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// Like USDC's blocklist: a blocked address can neither send nor receive.
    mapping(address => bool) public blocked;

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocklisted");
        super._update(from, to, value);
    }
}

/// Mimics Ethereum mainnet USDT: transfer/transferFrom return nothing.
contract MockUSDT {
    string public constant name = "Tether USD";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract SBXPresaleEscrowTest is Test {
    SBXPresaleEscrow escrow;
    MockUSDC usdc;
    MockUSDT usdt;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant USD = 1e6;
    uint256 constant SOFT_CAP = 1_000_000 * USD;
    uint64 start;
    uint64 deadline;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = uint64(block.timestamp);
        deadline = start + 90 days;

        usdc = new MockUSDC();
        usdt = new MockUSDT();
        IERC20[] memory coins = new IERC20[](2);
        coins[0] = IERC20(address(usdc));
        coins[1] = IERC20(address(usdt));
        escrow = new SBXPresaleEscrow(coins, SOFT_CAP, start, deadline, treasury);

        usdc.mint(alice, 2_000_000 * USD);
        usdt.mint(alice, 2_000_000 * USD);
        usdt.mint(bob, 2_000_000 * USD);
        vm.prank(alice);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(alice);
        usdt.approve(address(escrow), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(escrow), type(uint256).max);
    }

    function _deposit(address who, address coin, uint256 amount) internal {
        vm.prank(who);
        escrow.deposit(IERC20(coin), amount);
    }

    function test_SoftCapMissed_RefundsExactCoins() public {
        _deposit(alice, address(usdc), 300_000 * USD);
        _deposit(alice, address(usdt), 100_000 * USD);
        _deposit(bob, address(usdt), 200_000 * USD);

        vm.warp(deadline);
        assertTrue(escrow.refundsOpen());

        address[] memory buyers = new address[](3);
        buyers[0] = alice;
        buyers[1] = bob;
        buyers[2] = alice; // duplicate is skipped
        escrow.refundBatch(buyers);

        assertEq(usdc.balanceOf(alice), 2_000_000 * USD);
        assertEq(usdt.balanceOf(alice), 2_000_000 * USD);
        assertEq(usdt.balanceOf(bob), 2_000_000 * USD);
        assertEq(usdc.balanceOf(address(escrow)) + usdt.balanceOf(address(escrow)), 0);

        vm.expectRevert(SBXPresaleEscrow.NothingToRefund.selector);
        escrow.refund(alice);
    }

    function test_SoftCapMissed_TreasuryCannotWithdraw() public {
        _deposit(alice, address(usdc), 999_999 * USD);
        vm.warp(deadline);
        vm.expectRevert(SBXPresaleEscrow.SoftCapNotReached.selector);
        escrow.withdrawToTreasury();
    }

    function test_SoftCapReached_TreasuryGetsFunds_NoRefunds() public {
        _deposit(alice, address(usdc), 700_000 * USD);
        _deposit(bob, address(usdt), 300_000 * USD);

        vm.expectRevert(SBXPresaleEscrow.SaleNotOver.selector);
        escrow.withdrawToTreasury();

        vm.warp(deadline);
        vm.expectRevert(SBXPresaleEscrow.SoftCapReached.selector);
        escrow.refund(alice);

        escrow.withdrawToTreasury();
        assertEq(usdc.balanceOf(treasury), 700_000 * USD);
        assertEq(usdt.balanceOf(treasury), 300_000 * USD);

        vm.expectRevert(SBXPresaleEscrow.AlreadyWithdrawn.selector);
        escrow.withdrawToTreasury();
    }

    function test_NoRefundBeforeDeadline() public {
        _deposit(alice, address(usdc), 10 * USD);
        vm.expectRevert(SBXPresaleEscrow.SaleNotOver.selector);
        escrow.refund(alice);
    }

    function test_DepositWindow() public {
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(SBXPresaleEscrow.NotOpen.selector);
        escrow.deposit(IERC20(address(usdc)), 1);
    }

    function test_RejectsUnknownCoin() public {
        vm.prank(alice);
        vm.expectRevert(SBXPresaleEscrow.UnsupportedCoin.selector);
        escrow.deposit(IERC20(makeAddr("fake")), 1);
    }

    function testFuzz_RefundsReturnEverything(uint96 a, uint96 b) public {
        uint256 aa = bound(a, 1, 499_999 * USD);
        uint256 bb = bound(b, 1, 499_999 * USD);
        _deposit(alice, address(usdc), aa);
        _deposit(bob, address(usdt), bb);
        vm.warp(deadline);
        escrow.refund(alice);
        escrow.refund(bob);
        assertEq(usdc.balanceOf(alice), 2_000_000 * USD);
        assertEq(usdt.balanceOf(bob), 2_000_000 * USD);
    }

    // ---- a blocklisted buyer (reported by an outside reviewer, 2026-10) ----

    function test_Batch_SkipsBlocklistedBuyer_RefundsTheRest() public {
        _deposit(alice, address(usdc), 300_000 * USD);
        _deposit(bob, address(usdt), 200_000 * USD);
        usdc.setBlocked(alice, true);
        vm.warp(deadline);

        address[] memory buyers = new address[](2);
        buyers[0] = alice;
        buyers[1] = bob;
        vm.expectEmit(true, false, false, false, address(escrow));
        emit SBXPresaleEscrow.RefundSkipped(alice, "");
        escrow.refundBatch(buyers);

        assertEq(usdt.balanceOf(bob), 2_000_000 * USD, "bob refunded");
        assertEq(usdc.balanceOf(address(escrow)), 300_000 * USD, "alice's USDC stays frozen in escrow");
        assertEq(escrow.contributed(alice), 300_000 * USD, "alice still owed");

        // Once the coin's issuer lifts the block, the refund goes through.
        usdc.setBlocked(alice, false);
        escrow.refund(alice);
        assertEq(usdc.balanceOf(alice), 2_000_000 * USD);
    }

    function test_RefundCoin_ReturnsTheUnblockedCoin() public {
        _deposit(alice, address(usdc), 300_000 * USD);
        _deposit(alice, address(usdt), 100_000 * USD);
        usdc.setBlocked(alice, true);
        vm.warp(deadline);

        vm.expectRevert();
        escrow.refund(alice); // USDC refuses, so the whole call reverts...

        escrow.refundCoin(alice, IERC20(address(usdt))); // ...but USDT can come back on its own
        assertEq(usdt.balanceOf(alice), 2_000_000 * USD);
        assertEq(escrow.contributed(alice), 300_000 * USD);

        vm.expectRevert(SBXPresaleEscrow.NothingToRefund.selector);
        escrow.refundCoin(alice, IERC20(address(usdt)));
    }

    function test_RefundCoin_OnlyAfterAMissedSoftCap() public {
        _deposit(alice, address(usdt), 10 * USD);
        vm.expectRevert(SBXPresaleEscrow.SaleNotOver.selector);
        escrow.refundCoin(alice, IERC20(address(usdt)));
        vm.expectRevert(SBXPresaleEscrow.SaleNotOver.selector);
        escrow.refundBatch(new address[](0));
    }

    function test_RefundsNeverGoAnywhereButTheBuyer() public {
        _deposit(alice, address(usdc), 50 * USD);
        vm.warp(deadline);
        vm.prank(bob); // anyone may trigger it, but alice is paid
        escrow.refundCoin(alice, IERC20(address(usdc)));
        assertEq(usdc.balanceOf(alice), 2_000_000 * USD);
        assertEq(usdc.balanceOf(bob), 0);
    }
}
