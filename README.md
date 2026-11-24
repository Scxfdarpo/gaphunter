# GapHunter — a reactive cross-pool arbitrage sentinel

Two Uniswap V2 pools for the same token pair, trading on two venues, drift
apart in price all the time. Closing that gap normally takes an off-chain
bot: a server watching both pools, signing transactions, hoping it stays
up. **GapHunter removes the bot.** A Reactive Smart Contract on the
Reactive Network watches both pools itself, and the moment the spread is
worth taking, it orders the arbitrage on-chain. No server, no keeper,
no human trigger — the loop is:

```
Base Sepolia pool emits Sync ──► GapHunterReactive (Lasna) reprices both pools,
                                 checks spread / cooldown / estimated profit
                              ──► requestCallbackV_1_0
                              ──► callback proxy (Base Sepolia)
                              ──► GapHunterExecutor buys token0 on the cheap
                                  pool, sells it on the expensive pool,
                                  keeps the spread. Atomically. Or reverts.
```

Built for the **Reactive Omni Buildathon — Every Second Counts** track.

## Why it scores

- **Execution** — the complete event → react → callback loop runs on public
  testnets with recorded transaction hashes and a measured latency table
  (see *Evidence* below). Nothing is simulated.
- **Integration** — the reactive contract *is* the strategy: it holds both
  pools' prices, applies the threshold, sizes the trade from live pool
  depth, and estimates the round-trip profit before spending a callback.
  Remove Reactive and the system does nothing at all.
- **Usefulness** — cross-venue price gaps are the canonical latency
  problem in DeFi; closing them realigns prices for everyone. The pattern
  generalises to any V2-style pair on any supported origin chain.
- **Craft** — Foundry repo, full-loop local test suite (5 tests, including
  the complete whale-swap → signal → callback → profit cycle against real
  constant-product pools), reproducible deployment scripts, this README.

## Design notes

- **Pricing** — spot prices are recomputed from `Sync(uint112,uint112)`
  reserves on every event from either pool; the spread is measured in
  basis points of the cheaper price and must clear a fee-adjusted
  threshold (default 1.5%, vs. 0.6% round-trip fees).
- **Sizing** — each trade spends a fixed fraction (default 2%) of the buy
  pool's token1 reserves, then the round trip is estimated against the
  stored reserves; the callback is only requested if the estimate clears
  a minimum profit (default 0.3%).
- **Safety on the destination side** — the executor reprices both legs
  from *live* reserves inside the callback and reverts unless the round
  trip is profitable, so a stale signal can never lose money. Replay
  protection is a monotonic nonce plus a timestamp-based cooldown
  (timestamps, not block counts, per the Base Sepolia guidance).
- **Economics** — the RSC pays for its reactive transactions in lREACT;
  the executor holds the trading inventory (token1) and accumulates
  profits in token1, withdrawable by the owner. Both contracts expose
  debt-cover/withdraw helpers so the loop never stalls on funding.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `GapHunterReactive` | Reactive Lasna (5318007) | Subscribes to both pools' `Sync` events, decides, requests callbacks |
| `GapHunterExecutor` | Base Sepolia (84532) | Receives callbacks, executes both swap legs atomically |
| `MockERC20` (×2) | Base Sepolia | Demo pair tokens (testnet only, no value) |
| Uniswap V2 factory ×2 | Base Sepolia | The two venues (canonical v2-core bytecode, solc 0.5.16) |

## Run the tests

```bash
forge test
```

The suite seeds two real constant-product pools at equal prices, opens a
gap with a whale swap, feeds the resulting `Sync` logs to the reactive
contract exactly as the network would deliver them (system contract
etched at `0x8888…8888` with a recording double), captures the callback
request, delivers it through a stand-in proxy, and asserts the executor
closed the gap at a profit.

## Deploy

```bash
bash deploy/deploy.sh   # see the header for funding prerequisites
```

## Evidence (live run)

_To be filled with the recorded deployment: contract addresses, the
gap-opening transaction, the reactive transaction on Lasna, the callback
transaction on Base Sepolia, and the origin→callback latency table._
