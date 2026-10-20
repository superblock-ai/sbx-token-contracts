// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SBX presale escrow with soft-cap refund
/// @notice Holds presale stablecoin payments until the deadline.
///         - Soft cap reached by the deadline: funds can be sent to the treasury (anyone may trigger).
///         - Soft cap missed: every buyer is refunded exactly what they paid, in the coin they paid with.
///           Anyone (the buyer, or a keeper bot for "automatic" refunds) can trigger a refund, and
///           nobody - including the team - can withdraw the funds instead.
/// @dev No owner and no admin functions: the outcome depends only on deposits and the deadline.
///      Accepted coins must use 6 decimals (USDT/USDC on Ethereum and Polygon), so amounts are USD with
///      6 decimals.
contract SBXPresaleEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public immutable softCap;
    uint64 public immutable startTime;
    uint64 public immutable deadline;
    address public immutable treasury;

    mapping(IERC20 coin => bool) public accepted;
    IERC20[] private _coins;

    mapping(address buyer => mapping(IERC20 coin => uint256)) public deposits;
    mapping(address buyer => uint256) public contributed;
    uint256 public totalRaised;
    bool public withdrawn;

    event Deposited(address indexed buyer, IERC20 indexed coin, uint256 amount);
    event Refunded(address indexed buyer, IERC20 indexed coin, uint256 amount);
    /// @notice A batch refund for `buyer` failed (for example, a coin has blocklisted the address)
    ///         and was skipped so the rest of the batch could go through.
    event RefundSkipped(address indexed buyer, bytes reason);
    event Withdrawn(address indexed treasury, uint256 totalRaised);

    error ZeroAddress();
    error InvalidTimes();
    error UnsupportedCoin();
    error CoinNotSixDecimals();
    error ZeroAmount();
    error NotOpen();
    error SaleNotOver();
    error SoftCapNotReached();
    error SoftCapReached();
    error NothingToRefund();
    error AlreadyWithdrawn();

    constructor(IERC20[] memory coins, uint256 softCap_, uint64 startTime_, uint64 deadline_, address treasury_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (deadline_ <= startTime_ || softCap_ == 0) revert InvalidTimes();
        for (uint256 i = 0; i < coins.length; i++) {
            if (address(coins[i]) == address(0)) revert ZeroAddress();
            if (IERC20Metadata(address(coins[i])).decimals() != 6) revert CoinNotSixDecimals();
            accepted[coins[i]] = true;
            _coins.push(coins[i]);
        }
        softCap = softCap_;
        startTime = startTime_;
        deadline = deadline_;
        treasury = treasury_;
    }

    // ---- buying ----

    /// @notice Pay `amount` of `coin` (needs prior approval). Counted toward the soft cap.
    function deposit(IERC20 coin, uint256 amount) external nonReentrant {
        if (!accepted[coin]) revert UnsupportedCoin();
        if (block.timestamp < startTime || block.timestamp >= deadline) revert NotOpen();
        if (amount == 0) revert ZeroAmount();

        // Credit what actually arrived, in case a coin ever enables transfer fees (USDT can).
        uint256 before = coin.balanceOf(address(this));
        coin.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = coin.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        deposits[msg.sender][coin] += received;
        contributed[msg.sender] += received;
        totalRaised += received;
        emit Deposited(msg.sender, coin, received);
    }

    // ---- outcome ----

    function softCapReached() public view returns (bool) {
        return totalRaised >= softCap;
    }

    function refundsOpen() public view returns (bool) {
        return block.timestamp >= deadline && !softCapReached();
    }

    /// @notice Soft cap missed: return `buyer`'s full payment, in every coin they paid with.
    ///         Anyone may call for any buyer; the money only ever goes to the buyer's own address.
    /// @dev Reverts if any coin refuses the transfer (for example, USDC or USDT has blocklisted the
    ///      buyer). Use `refundCoin` to return the other coins in that case.
    function refund(address buyer) public nonReentrant {
        _checkRefundsOpen();
        if (contributed[buyer] == 0) revert NothingToRefund();
        for (uint256 i = 0; i < _coins.length; i++) {
            _refundCoin(buyer, _coins[i]);
        }
    }

    /// @notice Soft cap missed: return what `buyer` paid in one coin. Lets a buyer whom one coin has
    ///         blocklisted still get the other coins back.
    /// @dev There is deliberately no way to send a refund anywhere but the buyer's own address. A
    ///      stablecoin issuer usually blocklists an address for sanctions or a legal order; redirecting
    ///      its refund would move frozen funds. Those funds stay here until the issuer lifts the block.
    function refundCoin(address buyer, IERC20 coin) external nonReentrant {
        _checkRefundsOpen();
        if (!accepted[coin] || deposits[buyer][coin] == 0) revert NothingToRefund();
        _refundCoin(buyer, coin);
    }

    /// @notice Refund many buyers in one transaction (for a keeper bot). Skips buyers already refunded,
    ///         and skips (with `RefundSkipped`) any buyer whose refund fails, so one blocklisted
    ///         address cannot stall everyone else's refund.
    function refundBatch(address[] calldata buyers) external {
        _checkRefundsOpen();
        for (uint256 i = 0; i < buyers.length; i++) {
            if (contributed[buyers[i]] == 0) continue;
            // An external self-call, so a failed refund unwinds only its own state.
            try this.refund(buyers[i]) {}
            catch (bytes memory reason) {
                emit RefundSkipped(buyers[i], reason);
            }
        }
    }

    function _checkRefundsOpen() private view {
        if (block.timestamp < deadline) revert SaleNotOver();
        if (softCapReached()) revert SoftCapReached();
    }

    function _refundCoin(address buyer, IERC20 coin) private {
        uint256 amount = deposits[buyer][coin];
        if (amount == 0) return;
        deposits[buyer][coin] = 0;
        contributed[buyer] -= amount;
        coin.safeTransfer(buyer, amount);
        emit Refunded(buyer, coin, amount);
    }

    /// @notice Soft cap met and sale over: send all funds to the treasury. Anyone may call.
    function withdrawToTreasury() external nonReentrant {
        if (block.timestamp < deadline) revert SaleNotOver();
        if (!softCapReached()) revert SoftCapNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        for (uint256 i = 0; i < _coins.length; i++) {
            uint256 balance = _coins[i].balanceOf(address(this));
            if (balance != 0) _coins[i].safeTransfer(treasury, balance);
        }
        emit Withdrawn(treasury, totalRaised);
    }

    function coins() external view returns (IERC20[] memory) {
        return _coins;
    }
}
