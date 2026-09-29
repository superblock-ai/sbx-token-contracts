// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SBXToken} from "./SBXToken.sol";

/// @title SBX allocation manager
/// @notice The token's only minter. Mints never exceed the published tokenomics:
///
///   | Bucket                  | Share | SBX         | Released                                  |
///   |-------------------------|-------|-------------|-------------------------------------------|
///   | Market maker / liquidity|   5%  |  50,000,000 | Minted at TGE ({initialize})              |
///   | Presale                 |  10%  | 100,000,000 | Minted at TGE into the vesting contract   |
///   | Public sale A           |  10%  | 100,000,000 | DAO + Board vote after phase 1 milestones |
///   | Public sale B           |  10%  | 100,000,000 | DAO + Board vote after phase 2 milestones |
///   | Foundation / Treasury   |  65%  | 650,000,000 | DAO + Board vote, max 2.5% per 30 days    |
///
///         Any unminted allocation can be permanently burned by DAO vote with {retire}.
///
/// @dev `owner` is the DAO timelock, so every mint after TGE goes through a Governor proposal that
///      also has Board approval (see {SBXGovernor}).
contract SBXAllocationManager is Ownable {
    enum Bucket {
        MarketMaker,
        Presale,
        PublicSaleA,
        PublicSaleB,
        Treasury
    }

    uint256 public constant MARKET_MAKER_CAP = 50_000_000 ether;
    uint256 public constant PRESALE_CAP = 100_000_000 ether;
    uint256 public constant PUBLIC_SALE_A_CAP = 100_000_000 ether;
    uint256 public constant PUBLIC_SALE_B_CAP = 100_000_000 ether;
    uint256 public constant TREASURY_CAP = 650_000_000 ether;

    /// @notice 2.5% of total supply may be minted from the treasury per epoch.
    uint256 public constant TREASURY_EPOCH_LIMIT = 25_000_000 ether;
    uint256 public constant TREASURY_EPOCH = 30 days;

    address public immutable deployer;

    SBXToken public token;
    uint256 public tgeTimestamp;

    mapping(Bucket => uint256) public minted;
    /// @notice Unminted allocation permanently cancelled by DAO vote ("burned before minting").
    mapping(Bucket => uint256) public retired;
    mapping(uint256 epoch => uint256) public treasuryMintedInEpoch;

    event Initialized(address token, address presaleVesting, address marketMaker, uint256 marketMakerAmount);
    event AllocationMinted(Bucket indexed bucket, address indexed to, uint256 amount);
    event AllocationRetired(Bucket indexed bucket, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error NotDeployer();
    error ZeroAddress();
    error ZeroAmount();
    error BucketCapExceeded(Bucket bucket, uint256 remaining);
    error TreasuryEpochLimitExceeded(uint256 remainingThisEpoch);
    error BucketMintedAtTge();

    constructor(address timelock) Ownable(timelock) {
        deployer = msg.sender;
    }

    /// @notice One-shot TGE setup: wires the token and mints the presale and market-maker allocations.
    /// @param marketMakerAmount Portion of the 50M market-maker bucket to release at TGE. The rest can be
    ///        minted later by DAO vote.
    function initialize(SBXToken token_, address presaleVesting, address marketMaker, uint256 marketMakerAmount)
        external
    {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(token) != address(0)) revert AlreadyInitialized();
        if (address(token_) == address(0) || presaleVesting == address(0)) revert ZeroAddress();
        if (marketMakerAmount != 0 && marketMaker == address(0)) revert ZeroAddress();

        token = token_;
        tgeTimestamp = block.timestamp;

        _mintFrom(Bucket.Presale, presaleVesting, PRESALE_CAP);
        if (marketMakerAmount != 0) _mintFrom(Bucket.MarketMaker, marketMaker, marketMakerAmount);

        emit Initialized(address(token_), presaleVesting, marketMaker, marketMakerAmount);
    }

    /// @notice Mint from a bucket. Callable only by the DAO timelock.
    function mint(Bucket bucket, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(0)) revert NotInitialized();
        if (bucket == Bucket.Presale) revert BucketMintedAtTge();
        if (to == address(0)) revert ZeroAddress();

        if (bucket == Bucket.Treasury) {
            uint256 epoch = currentTreasuryEpoch();
            uint256 used = treasuryMintedInEpoch[epoch];
            if (used + amount > TREASURY_EPOCH_LIMIT) revert TreasuryEpochLimitExceeded(TREASURY_EPOCH_LIMIT - used);
            treasuryMintedInEpoch[epoch] = used + amount;
        }

        _mintFrom(bucket, to, amount);
    }

    /// @notice Permanently burn unminted allocation, e.g. unsold Public Sale A/B or unused treasury.
    ///         Callable only by the DAO timelock. The retired amount can never be minted, so the
    ///         effective max supply drops by `amount`. Presale burns go through
    ///         {SBXPresaleVesting-burnUnallocated}; tokens the timelock holds are burned with {SBXToken-burn}.
    function retire(Bucket bucket, uint256 amount) external onlyOwner {
        if (bucket == Bucket.Presale) revert BucketMintedAtTge();
        if (amount == 0) revert ZeroAmount();
        uint256 left = remaining(bucket);
        if (amount > left) revert BucketCapExceeded(bucket, left);
        retired[bucket] += amount;
        emit AllocationRetired(bucket, amount);
    }

    /// @notice Most SBX that can still ever exist: live supply plus everything still mintable.
    function maxFutureSupply() external view returns (uint256) {
        uint256 mintable;
        for (uint256 b = 0; b <= uint256(Bucket.Treasury); b++) {
            mintable += remaining(Bucket(b));
        }
        return token.totalSupply() + mintable;
    }

    function currentTreasuryEpoch() public view returns (uint256) {
        return (block.timestamp - tgeTimestamp) / TREASURY_EPOCH;
    }

    function bucketCap(Bucket bucket) public pure returns (uint256) {
        if (bucket == Bucket.MarketMaker) return MARKET_MAKER_CAP;
        if (bucket == Bucket.Presale) return PRESALE_CAP;
        if (bucket == Bucket.PublicSaleA) return PUBLIC_SALE_A_CAP;
        if (bucket == Bucket.PublicSaleB) return PUBLIC_SALE_B_CAP;
        return TREASURY_CAP;
    }

    function remaining(Bucket bucket) public view returns (uint256) {
        return bucketCap(bucket) - minted[bucket] - retired[bucket];
    }

    function _mintFrom(Bucket bucket, address to, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 left = remaining(bucket);
        if (amount > left) revert BucketCapExceeded(bucket, left);
        minted[bucket] += amount;
        token.mint(to, amount);
        emit AllocationMinted(bucket, to, amount);
    }
}
