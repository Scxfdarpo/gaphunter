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
  testnets: **20 live full-loop runs, 20 executed, 0 refused**, latency
  p50 = p95 = 1 s, total profit +45,629.70 GTB, every run recorded with
  its transaction hashes (see *Evidence* below). Nothing is simulated.
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

## Evidence (live run, 2026-11-24)

Deployed and exercised end-to-end on public testnets. Deployer:
`0xdb75249615a23133fD10b8e96B9220EF1B950B5d`.

### Contracts

| Contract | Chain | Address |
| --- | --- | --- |
| Uniswap V2 factory A | Base Sepolia (84532) | `0x33bb79402a0802be06d8b9f2b6171e80e54b3222` |
| Uniswap V2 factory B | Base Sepolia (84532) | `0x62e4ca89558d7a553d165332efffadf8221a2f3b` |
| Gap Token A (token0) | Base Sepolia | `0x2250E6CAd8e9233eeb8f97434fA8aD2Cde071B1b` |
| Gap Token B (token1) | Base Sepolia | `0xD6a779b928d8F284C7A30347a8302e3E0579aA20` |
| Pair A (venue A) | Base Sepolia | `0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3` |
| Pair B (venue B) | Base Sepolia | `0x8e62F00356C75791570182bB1A412BC4129f387a` |
| **GapHunterReactive** | **Reactive Lasna (5318007)** | `0x33BB79402a0802bE06D8b9F2b6171e80e54B3222` |
| **GapHunterExecutor** | **Base Sepolia (84532)** | `0x986249121a4453294A68f6c7Cbc250Db6d30bF63` |

Both pairs seeded with 1,000,000 GTA / 1,000,000 GTB. The executor was
funded with 500,000 GTB of trading inventory.

### Full-loop runs

A whale swap on venue B (100,000 GTB in) knocks venue B's price ~10–21%
away from venue A. Nobody calls the executor: the pair's `Sync` event is
delivered to the reactive contract on Lasna, which reprices both pools,
confirms the spread clears its threshold, and requests a callback. The
executor then buys GTA on the cheap venue and sells it on the expensive
one, verifying profitability against live reserves before settling.

| # | Origin event (Base Sepolia) | Reactive tx (Lasna) | Callback execution (Base Sepolia) | Origin ts → callback ts | Executor GTB after |
| --- | --- | --- | --- | --- | --- |
| 1 | Whale swap `0x4a006218f4512ae3f8bc27b1841baf6f4d0a52da9b14cf522b7f6a33d2376494` (block 62994276), gap armed by a 1,000 GTB poke swap `0x77c4b3e8989d213932832bc324b9e23776dcb42a6d5bb4e5d133a241ed07ad9f` (block 62995152) | `0xcf1dc1b75a912757d83d9843a16146ad9281bc656ac11beeb199d73195af89ab` (block 9134595) — `PriceSeen`, `CallbackRequested`, `ArbSignalled` | `0x52a56282428e1da07843aee47a8a4a470e9f1e44a6c46fa47d97c7ca2da48d9a` (block 62995159) | 1795520899 → 1795520900 (**≈1 s**, 7 blocks) | 500,000 → **503,041.01** (+3,041.01) |
| 2 | Whale swap `0x65ba04618c8ec579ec65271ef1bdb69a3d6d60739ee46be6d625f111ceb72254` (block 62995873) | `0xdfed9b8a354cb7c76018bc09d84b692d1c9ba4bd6cef3c03eb107372d3a3342d` (block 9134732) — `ArbSignalled` nonce 2 | `0x81d3308961347438675a4ac26a2d17c13142accb72cbb5cc7faa2fdefc764ffc` (block 62995880) | 1795521043 → 1795521044 (**≈1 s**, 7 blocks) | 503,041.01 → **508,469.68** (+5,428.67) |

Run 1 needed the extra poke because the reactive contract was deployed
after the pairs were seeded, so it had not yet seen a `Sync` from venue A;
run 2 is the clean single-event loop — one whale swap, one reactive
reaction, one profitable arbitrage, about a second end to end, with no
off-chain keeper anywhere in the loop. Total realised profit across the
two runs: **+8,469.68 GTB** on 500,000 GTB of inventory.

*Address note:* factory A on Base Sepolia and `GapHunterReactive` on
Lasna share the address `0x33BB79402a…` because the same deployer wallet
deployed both at the same nonce on two different chains. Same string,
different chains — expected, not an error.

### Batch extension (2026-11-25): 20 runs, with a polling baseline

Runs 3–20 repeated the loop with alternating whale direction (18 runs,
100,000–200,000 tokens per whale swap). Every callback was verified
on-chain via its `ArbExecuted` log and the executor's balance delta.

- **20 runs total: 20 executed, 0 refused, 0 failed.**
- **Latency: p50 = 1 s, p95 = 1 s** (Base Sepolia block timestamps;
  median 5.5 blocks, origin event → callback executed).
- **Profit: +37,160.02 GTB in the batch; +45,629.70 GTB across all 20
  runs.** On-chain reconciliation is exact: the executor's `totalProfit`
  counter reads 45,629.698188 GTB and its balance is 545,629.70 GTB =
  500,000 inventory + total profit.
- Per-run records (whale / reactive / callback hashes, timestamps,
  profit): [`evidence/runs.json`](evidence/runs.json).

During the batch, a baseline poller sampled both pairs' reserves every
2 seconds (762 samples, [`evidence/baseline.md`](evidence/baseline.md)).
A polling keeper would have **missed 2 of the 18 gaps entirely**: on
those thin runs the reactive loop executed ~1 s after the whale swap
and knocked the spread below the 150 bps threshold before the poller's
next tick — at polling cadence, those opportunities never existed. On
the gaps it did catch, the poller's *detection* lag (median 0.28 s) is
only the first half of its problem: it still has to sign and land its
own transaction from a server that must stay up. The reactive numbers
above are the full loop, executed, with no server at all.

### Limitations

- Testnet demonstration: both venues are self-deployed Uniswap V2
  pools and GTA/GTB are valueless demo tokens; the price gaps are
  opened by our own whale swaps. What is proven is the pattern — a
  contract that watches, decides and executes with no off-chain
  component — not mainnet profitability.
- We checked mainnet ourselves: a 20-minute scan of Base mainnet
  (3,000 samples across the deepest V2-style pairs) found **zero**
  net-profitable gaps after the ~60 bps two-leg fee hurdle. On live
  markets this design would need a structurally different edge
  (near-zero-fee venues or sub-block execution); we say so rather than
  imply otherwise.
- Latency is measured on Base Sepolia block timestamps (1-second
  granularity); sub-second differences are not resolvable from chain
  data.
