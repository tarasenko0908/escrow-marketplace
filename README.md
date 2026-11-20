# Escrow Marketplace

Stablecoin escrow for deals between a buyer and a seller — freelance work, marketplace orders, deliveries.
The buyer's payment is locked in the contract and released only when the work is accepted, the review period expires, or an arbiter resolves a dispute.

## Deal lifecycle

```
            markDelivered (seller)                 confirm (buyer) / claimAfterReview (anyone)
  Funded ─────────────────────────► Delivered ─────────────────────────────────────────► Completed
    │                                   │
    ├── cancel (buyer, after deadline) ─┼──► Refunded
    ├── refundBuyer (seller) ───────────┘
    │
    └── openDispute (buyer/seller) ──► Disputed ── resolveDispute (arbiter) ──► Resolved
```

## Features

- **Protection for both sides**
  - Buyer: full refund if the seller doesn't deliver before the deadline
  - Seller: if the buyer stays silent after delivery, the deal auto-completes after the review period
- **Disputes** — the arbiter can split funds in any proportion (e.g. 60/40)
- **Platform fee** in basis points (max 10%), charged only on the seller's payout; each deal stores a fee snapshot so later fee changes don't affect it
- Works with any ERC-20 stablecoin via `SafeERC20` (including USDT)
- `ReentrancyGuard`, custom errors, events for every transition

## Contract overview

| Function | Who | Description |
|---|---|---|
| `createDeal(seller, amount, deadline)` | buyer | Lock payment (approve first) |
| `markDelivered(dealId)` | seller | Mark as delivered, starts the review period |
| `confirm(dealId)` | buyer | Accept and pay the seller |
| `claimAfterReview(dealId)` | anyone | Complete after the review period |
| `cancel(dealId)` | buyer | Refund if not delivered by the deadline |
| `refundBuyer(dealId)` | seller | Voluntary refund |
| `openDispute(dealId)` | buyer / seller | Freeze for arbitration |
| `resolveDispute(dealId, sellerShareBps)` | arbiter | Split the escrow |
| `setFee`, `setArbiter`, `setReviewPeriod` | owner | Platform settings |

## Getting started

```bash
npm install
npx hardhat compile
npx hardhat test
npm run coverage
```

## Tests

18 tests: deal creation and validation, confirmation, auto-completion, fee snapshots, refunds and deadlines, disputes and splits, double-payment protection, access control.

```
  18 passing
```

Line coverage: 100%.

## Tech stack

Solidity 0.8.24 · OpenZeppelin Contracts 5 · Hardhat · Ethers v6 · Chai

## License

MIT
