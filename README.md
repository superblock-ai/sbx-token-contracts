# SBX Token Contracts

Smart contracts for the [Superblock](https://superblock.ai) (SBX) token: a capped ERC-20, DAO governance, presale vesting and a soft-cap refund escrow.

> **Status: not deployed, not audited.** Contract addresses and the audit report will be published here once available.

## Contracts

| Contract | Purpose |
|---|---|
| [`SBXToken`](src/SBXToken.sol) | ERC-20 "Superblock" / "SBX". Hard cap of 1,000,000,000. Burnable, EIP-2612 permit, ERC20Votes with a timestamp clock. Only `SBXAllocationManager` can mint. |
| [`SBXAllocationManager`](src/SBXAllocationManager.sol) | The token's only minter. Enforces the tokenomics allocations on-chain and is owned by the DAO timelock. |
| [`SBXPresaleVesting`](src/SBXPresaleVesting.sol) | Holds the 100M presale allocation. Buyers register their allocation with a Merkle proof. Release begins only after a DAO vote, followed by a 12-month cliff and 12-month linear vesting. |
| [`SBXPresaleEscrow`](src/SBXPresaleEscrow.sol) | Holds USDT/USDC paid into it until a deadline. If the soft cap is missed, every buyer gets back exactly what they paid, and anyone (or a keeper bot) can trigger the refunds. If the soft cap is met, funds go to the treasury. No owner or admin functions. |
| [`SBXGovernor`](src/SBXGovernor.sol) | OpenZeppelin Governor with a timelock. Every passed proposal also needs Board multisig approval. |

## Tokenomics

Total supply is capped at **1,000,000,000 SBX**. Each allocation is enforced by `SBXAllocationManager`:

| Allocation | Share | SBX | Release |
|---|---|---|---|
| Market maker / exchange liquidity | 5% | 50,000,000 | Minted at TGE |
| Presale | 10% | 100,000,000 | Minted at TGE into `SBXPresaleVesting`. DAO vote starts a 12-month cliff, then 12-month linear vesting |
| Public sale A | 10% | 100,000,000 | DAO and Board approval after phase 1 milestones |
| Public sale B | 10% | 100,000,000 | DAO and Board approval after phase 2 milestones |
| Foundation / Treasury | 65% | 650,000,000 | DAO and Board approval, at most 25,000,000 (2.5%) per 30 days |

The presale is split across 10 phases of 10,000,000 SBX each.

## DAO-approved burns

Apart from holders burning their own tokens, every burn goes through a DAO vote, Board approval and the timelock:

| What is burned | Call (proposal target) |
|---|---|
| Unsold presale tokens | `SBXPresaleVesting.burnUnallocated(amount)`. Buyers' allocations cannot be touched. |
| Unminted allocation (unsold Public Sale A/B, unused treasury or market-maker allocation) | `SBXAllocationManager.retire(bucket, amount)`. Retired allocation can never be minted. |
| SBX held by the DAO timelock | `SBXToken.burn(amount)` |

`SBXAllocationManager.maxFutureSupply()` returns the most SBX that can ever exist after burns.

## Governance flow

1. A holder with at least 100,000 votes submits a proposal.
2. After a 1-day delay, voting runs for 7 days. Quorum is 4% of total supply.
3. The Board multisig approves the proposal with `SBXGovernor.approveProposal(id)`.
4. The proposal is queued in the timelock and can be executed after 2 days.

Voting power is delegated SBX plus any registered, unreleased presale allocation. Presale buyers can vote while their tokens are still vesting.

## Development

Built with [Foundry](https://getfoundry.sh) and [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.4.

```bash
git clone --recursive https://github.com/superblock-ai/sbx-token-contracts
forge build
forge test
```

## License

MIT
