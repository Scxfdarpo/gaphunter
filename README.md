# GapHunter — a reactive cross-pool arbitrage sentinel

Two Uniswap V2 pools for the same token pair, trading on two venues, drift
apart in price all the time. Closing that gap normally takes an off-chain
bot: a server watching both pools, signing transactions, hoping it stays
up. **GapHunter removes the bot.** A Reactive Smart Contract on the
Reactive Network watches both pools itself, and the moment the spread is
worth taking, it orders the arbitrage on-chain. No server, no keeper,
no human trigger — the loop is:

```
Origin-chain pool emits Sync ──► GapHunterReactive (Lasna) reprices both pools,
                                 checks spread / cooldown / estimated profit
                              ──► requestCallbackV_1_0
                              ──► callback proxy (origin chain)
                              ──► GapHunterExecutor buys token0 on the cheap
                                  pool, sells it on the expensive pool,
                                  keeps the spread. Atomically. Or reverts.
```

The system runs on **two origin chains** — Base Sepolia and Unichain
Sepolia — each with its own reactive contract on Lasna and its own
executor, sharing no off-chain component at all.

Built for the **Reactive Omni Buildathon — Every Second Counts** track.

## Why it scores

- **Execution** — the complete event → react → callback loop ran live on
  public testnets **320 times: 300 recorded runs on Base Sepolia and 20
  on Unichain Sepolia, every single one executed, 0 refused, 0 failed.**
  Base latency p50 1 s / p95 2 s; Unichain p50 2 s / p95 3 s. Total
  realised profit **+952,227.72 GTB** (Base, on-chain counter) and
  **+36,482.76 GTA** (Unichain, on-chain counter), reconciled against
  the executors' own counters below. Nothing is simulated.
- **Integration** — the reactive contract *is* the strategy: it holds both
  pools' prices, applies the threshold, sizes the trade from live pool
  depth, and estimates the round-trip profit before spending a callback.
  Remove Reactive and the system does nothing at all. Lasna sits in the
  middle of both legs, as the track requires.
- **Usefulness** — cross-venue price gaps are the canonical latency
  problem in DeFi; closing them realigns prices for everyone. The pattern
  generalises to any V2-style pair on any supported origin chain — the
  second chain was added by redeploying the same contracts, unchanged.
- **Craft** — Foundry repo, **66 tests, all passing**: the full
  whale → signal → callback → profit loop against real constant-product
  pools, 12 guard tests for the threshold / cooldown / replay / profit
  gates, **48 fuzz/property tests at 256 runs each** (including a
  pricing-model equivalence proof: the executor executes if and only if
  the constant-product model says the round trip is profitable, and
  books exactly the modelled profit), and a **12-property invariant
  campaign (128,000 stateful handler calls per full run)** covering
  nonce discipline and the executor's balance identity. **Slither
  static analysis** is published with honest dispositions (0 High,
  3 Medium, 10 Low, 6 Informational — see
  [`SECURITY.md`](SECURITY.md)), both Base-leg contracts are
  **Sourcify-verified with an exact match**, and there is a live
  dashboard reading the chain directly, reproducible deployment
  scripts, and this README.

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
  debt-cover/withdraw helpers so the loop never stalls on funding —
  exercised in production: when an RSC's balance hit zero mid-batch it
  accrued system debt and deliveries paused; the debt was repaid through
  the owner `withdraw` path and the loop resumed (see Evidence notes).

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `GapHunterReactive` | Reactive Lasna (5318007) | Base leg: subscribes to both Base pools' `Sync` events, decides, requests callbacks |
| `GapHunterExecutor` | Base Sepolia (84532) | Base leg: receives callbacks, executes both swap legs atomically |
| `GapHunterReactive` #2 | Reactive Lasna (5318007) | Unichain leg: same contract, origin chain 1301 |
| `GapHunterExecutor` #2 | Unichain Sepolia (1301) | Unichain leg executor |
| `MockERC20` (×2) | both origin chains | Demo pair tokens (testnet only, no value) |
| Uniswap V2 factory ×2 | both origin chains | The two venues per chain (canonical v2-core bytecode, solc 0.5.16) |

## Run the tests

```bash
forge test
```

The suite seeds two real constant-product pools at equal prices, opens a
gap with a whale swap, feeds the resulting `Sync` logs to the reactive
contract exactly as the network would deliver them (system contract
etched at `0x8888…8888` with a recording double), captures the callback
request, delivers it through a stand-in proxy, and asserts the executor
closed the gap at a profit. The guard suite pins down the RSC's
threshold, cooldown, sizing and minimum-profit gates and the executor's
live-reprice revert, replay protection and owner-only paths.

On top of those 17 scenario tests, `test/GapHunterFuzz.t.sol` (32) and
`test/GapHunterProperties.t.sol` (16) state the system's safety claims
as fuzzed properties at 256 runs each — signal gates at randomized
thresholds and parameters, nonce monotonicity, both cooldowns at their
boundaries, guard modifiers under fuzzed callers, event contents
recomputed independently from live reserves, and the executor's
execute-if-and-only-if-profitable equivalence with the pricing model.
`test/GapHunterInvariant.t.sol` adds a stateful campaign: a handler
drives whales, Sync deliveries, noise logs, time travel, retunes and
callback deliveries in random order while 12 invariants (nonce
discipline, balance identity, stored-reserve freshness, callback
routing) are checked after every sequence — 256 runs × 500 calls =
128,000 handler calls in a default run. Static analysis (Slither) and
the disposition of every finding are in [`SECURITY.md`](SECURITY.md),
with raw reports under [`analysis/`](analysis/).

## Deploy

```bash
bash deploy/deploy.sh            # Base Sepolia leg
bash deploy/deploy-unichain.sh   # Unichain Sepolia leg
```

## Evidence (live runs, 2026-11-24 → 2026-11-26)

Deployed and exercised end-to-end on public testnets. Deployer:
`0xdb75249615a23133fD10b8e96B9220EF1B950B5d`.

### Contracts — Base Sepolia leg

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

### Contracts — Unichain Sepolia leg

| Contract | Chain | Address |
| --- | --- | --- |
| Uniswap V2 factory A | Unichain Sepolia (1301) | `0x33bb79402a0802be06d8b9f2b6171e80e54b3222` |
| Uniswap V2 factory B | Unichain Sepolia (1301) | `0x62e4ca89558d7a553d165332efffadf8221a2f3b` |
| Pair A / Pair B | Unichain Sepolia | `0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3` / `0x8e62F00356C75791570182bB1A412BC4129f387a` |
| **GapHunterReactive #2** | **Reactive Lasna (5318007)** | `0xD6a779b928d8F284C7A30347a8302e3E0579aA20` |
| **GapHunterExecutor #2** | **Unichain Sepolia (1301)** | `0xBD1E78903d4703D7C1Ec1B044b2F807778CE5C53` |
| Callback proxy | Unichain Sepolia | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |

On this leg the pair's token1 is GTA (the mirror of the Base leg), so
the executor's inventory and profits are in GTA. It was funded with
500,000 GTA. (Factories and pairs carry the same addresses as the Base
leg — same deployer, same nonce sequence, CREATE2 pair derivation.)

### The first two runs (2026-11-24)

A whale swap on one venue (100,000 tokens in) knocks its price ~10–21%
away from the other. Nobody calls the executor: the pair's `Sync` event
is delivered to the reactive contract on Lasna, which reprices both
pools, confirms the spread clears its threshold, and requests a
callback. The executor then buys on the cheap venue and sells on the
expensive one, verifying profitability against live reserves before
settling.

| # | Origin event (Base Sepolia) | Reactive tx (Lasna) | Callback execution (Base Sepolia) | Origin ts → callback ts | Executor GTB after |
| --- | --- | --- | --- | --- | --- |
| 1 | Whale swap `0x4a006218f4512ae3f8bc27b1841baf6f4d0a52da9b14cf522b7f6a33d2376494` (block 62994276), gap armed by a 1,000 GTB poke swap `0x77c4b3e8989d213932832bc324b9e23776dcb42a6d5bb4e5d133a241ed07ad9f` (block 62995152) | `0xcf1dc1b75a912757d83d9843a16146ad9281bc656ac11beeb199d73195af89ab` (block 9134595) — `PriceSeen`, `CallbackRequested`, `ArbSignalled` | `0x52a56282428e1da07843aee47a8a4a470e9f1e44a6c46fa47d97c7ca2da48d9a` (block 62995159) | 1795520899 → 1795520900 (**≈1 s**, 7 blocks) | 500,000 → **503,041.01** (+3,041.01) |
| 2 | Whale swap `0x65ba04618c8ec579ec65271ef1bdb69a3d6d60739ee46be6d625f111ceb72254` (block 62995873) | `0xdfed9b8a354cb7c76018bc09d84b692d1c9ba4bd6cef3c03eb107372d3a3342d` (block 9134732) — `ArbSignalled` nonce 2 | `0x81d3308961347438675a4ac26a2d17c13142accb72cbb5cc7faa2fdefc764ffc` (block 62995880) | 1795521043 → 1795521044 (**≈1 s**, 7 blocks) | 503,041.01 → **508,469.68** (+5,428.67) |

Run 1 needed the extra poke because the reactive contract was deployed
after the pairs were seeded, so it had not yet seen a `Sync` from venue A;
run 2 is the clean single-event loop — one whale swap, one reactive
reaction, one profitable arbitrage, about a second end to end, with no
off-chain keeper anywhere in the loop.

*Address note:* factory A on Base Sepolia and `GapHunterReactive` on
Lasna share the address `0x33BB79402a…` because the same deployer wallet
deployed both at the same nonce on two different chains. Same string,
different chains — expected, not an error.

### The 300-run batch (Base Sepolia, 2026-11-25 → 2026-11-26)

Runs 3–300 repeated the loop with alternating whale direction
(100,000–200,000 tokens per whale swap). Every callback was verified
on-chain via its `ArbExecuted` log and the executor's balance delta,
and recorded with full hashes in
[`evidence/runs.json`](evidence/runs.json).

- **300 recorded runs: 300 executed, 0 refused, 0 failed.**
- **Latency: p50 = 1 s, p95 = 2 s** (origin block timestamp → callback
  block timestamp; blocks p50 6, p95 9).
- **Ledger profit: +950,523.88 GTB** across the 300 recorded runs.
- **On-chain reconciliation:** the executor's counters read
  `arbsExecuted = 301` and `totalProfit = +952,227.72 GTB`, and its
  balance is 1,452,227.72 GTB = 500,000 inventory + total profit. The
  one-execution difference is fully accounted for: during a host
  restart window, run 269's original attempt executed on-chain
  (arb nonce 269, callback
  `0xf0ee522ad9ce69135cbe8ae424203512e2786d3395f6d5a6b1bc52ff252b4de7`,
  block 63839007, **+1,703.84 GTB**) but the driver process died before
  checkpointing it; the restarted driver re-drove run 269, which is the
  recorded one (nonce 270). Ledger + that execution = the on-chain
  totals, exactly.
- Representative runs: #150 — whale
  `0x6ff1eed7eab09ec4655cceadb6ea0ae7d9e4d6571c9b5d5f5518d5e6703d3f1c`,
  react `0x50d4f2f53281afb1c810872a9f8a95f03d3abad53d89d78722427d0296439807`,
  callback `0xa368f703f727c6f2fb35e6859d8087e9ad7d51221ba259773519a5d0adb637da`
  (1 s, +1,495.10 GTB). #300 — whale
  `0xe3c40d96fcdde2395dcdb4ef5ca5c4955f962daa940d3a5a3d835716b81ffddb`,
  react `0xf035e00d66d3ff9d61878de3575e218a9324bdd20b3383665cf68fbe7cdfb862`,
  callback `0x18d752f8316be71b798f7c4667382dea6ab0a6b200e3e2679548a87a76c32e5c`
  (1 s, +1,726.32 GTB).

Running 300 loops also surfaced the operational edge cases, all handled
on-chain: the RSC burns ≈0.0448 lREACT per loop (measured, not
estimated); when its balance reached zero it accrued debt to the system
contract and deliveries stopped until the debt was repaid through the
owner `withdraw` path — after which the loop resumed on its own. A
watchdog restarted the (off-chain, test-only) batch driver after host
restarts; the arbitrage loop itself has no off-chain component.

### The Unichain leg (20 runs, 2026-11-25 → 2026-11-26)

The same contracts were redeployed against Unichain Sepolia pairs, with
a second reactive contract on Lasna (origin chain 1301). Per-run
records: [`evidence/unichain-runs.json`](evidence/unichain-runs.json).

- **20 runs: 20 executed, 0 refused, 0 failed.**
- **Latency: p50 = 2 s, p95 = 3 s** (blocks p50 2, p95 3).
- **Profit: +36,482.76 GTA.** On-chain reconciliation is exact:
  `arbsExecuted = 20`, `totalProfit = +36,482.76 GTA`, executor balance
  536,482.76 GTA = 500,000 inventory + total profit.
- Run 1: whale
  `0xad1018527828fce0ca2b0948d4c584913f3a8ddfe7b49d8cd41adba79703d4d9`,
  react `0x432892990f914df0b62be17eee4c65cb52f6eb3fc08ac53507c0ec4e481d848d`,
  callback `0x802d39fb0b7913be09cf66caac6f01ce18761f57e36e719c3825c5a6e45b7938`
  (3 s, +3,083.51 GTA). Run 20: whale
  `0x550a29624377505ba5617e1dc75b9bc45a4e02bde1296d82b93928e1f20299c6`,
  react `0x5f606301ce8572f37f47adfad50371a9b751d3b7294bbbe8fa4cd6707e54295e`,
  callback `0x391d75dfc3b9280619f0603fb4d315fe7c7cd027c6f0f41f767d145beeb5b7e5`
  (3 s, +962.22 GTA). Run 1's record was reconstructed from on-chain
  logs after the driver hit a lagging RPC node; every value in it was
  verified on-chain, and the file says so.

### Polling baseline (runs 3–50)

During runs 3–50 a baseline poller sampled both Base pairs' reserves
every 2 seconds (2,209 samples,
[`evidence/baseline.md`](evidence/baseline.md)). A polling keeper
would have **missed 5 of the 48 gaps entirely** (runs 6, 14, 31, 35,
41): on those runs the reactive loop executed ~1 s after the whale swap
and knocked the spread below the 150 bps threshold before the poller's
next tick — at polling cadence, those opportunities never existed. On
the gaps it did catch, the poller's *detection* lag (median 0.46 s,
max 5.25 s) is only the first half of its problem: it still has to sign
and land its own transaction from a server that must stay up. The
reactive numbers are the full loop, executed, with no server at all.
The poller only covered runs 3–50; no baseline is claimed beyond them.

### Verification & dashboard

- **Sourcify (exact match)** — Sourcify recompiled the sources in this
  repo and matched the deployed bytecode bit-for-bit:
  [`GapHunterExecutor` on Base Sepolia](https://repo.sourcify.dev/84532/0x986249121a4453294A68f6c7Cbc250Db6d30bF63),
  [`GapHunterReactive` on Lasna](https://repo.sourcify.dev/5318007/0x33BB79402a0802bE06D8b9F2b6171e80e54B3222).
  A byte-for-byte deployed-vs-compiled comparison script lives in
  `script/verify-deployment.sh`; see `VERIFICATION.md`.
- **Live dashboard** — [scxfdarpo.github.io/gaphunter](https://scxfdarpo.github.io/gaphunter/)
  reads both Base pairs' reserves, the executor's balance / totalProfit
  / arbsExecuted, and the run ledger straight from the chain and this
  repo. No backend.

### Limitations

- Testnet demonstration: both venues on each chain are self-deployed
  Uniswap V2 pools and GTA/GTB are valueless demo tokens; the price
  gaps are opened by our own whale swaps. What is proven is the
  pattern — a contract that watches, decides and executes with no
  off-chain component — not mainnet profitability.
- We checked mainnet ourselves: a 20-minute scan of Base mainnet
  (3,000 samples across the deepest V2-style pairs) found **zero**
  net-profitable gaps after the ~60 bps two-leg fee hurdle. On live
  markets this design would need a structurally different edge
  (near-zero-fee venues or sub-block execution); we say so rather than
  imply otherwise.
- Latency is measured on origin-chain block timestamps (1-second
  granularity); sub-second differences are not resolvable from chain
  data.
