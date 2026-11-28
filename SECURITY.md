# Security & verification

How GapHunter's two production contracts (`GapHunterReactive`,
`GapHunterExecutor`) are tested and statically analysed, what the tools
actually reported, and why each finding is acceptable. Every number
below is from a tool run executed on this repository; the raw outputs
are committed under [`analysis/`](analysis/).

## Test suite — `forge test`: 66 tests, all passing

| Suite | Tests | What it pins down |
| --- | --- | --- |
| `test/GapHunter.t.sol` | 5 | The scripted full loop: whale → Sync → signal → callback → profit, against real constant-product pools |
| `test/GapHunterGuards.t.sol` | 12 | The gates at hand-picked values: threshold, both cooldowns, sizing, minimum profit, replay, pair mismatch, owner-only surface |
| `test/GapHunterFuzz.t.sol` | 32 | Property/fuzz tests, 256 runs each: the executor executes **iff** the constant-product model says the round trip is profitable and books exactly the modelled profit; RSC signal gates at fuzzed thresholds / profit gates / fractions; nonce monotonicity; both cooldowns at fuzzed boundaries; `onlySystem` / `onlyServiceProvider` / `onlyCallbackSender` under fuzzed callers and senders |
| `test/GapHunterProperties.t.sol` | 16 | End-to-end loop properties under fuzzed gaps: execution strictly narrows the spread it traded on; repeated gap cycles advance nonces and counts in lockstep; `ArbSignalled` / `ArbExecuted` event fields equal an independent recomputation from live reserves; callback routing (recipient, chain, gas limit); owner rescue/withdraw move exact amounts; extreme (near-`uint112`-ceiling, maximally skewed) reserve shapes still produce decisions, not panics |
| `test/GapHunterInvariant.t.sol` | 12 properties | Stateful invariant campaign: a handler drives whales, Sync deliveries, noise logs, block/time travel, owner retunes and callback deliveries in random order. **256 runs × 500 calls = 128,000 handler calls, 0 reverts** in a default `forge test` run. Invariants include: RSC nonce == signals issued; executor nonce never exceeds the RSC's; executions on-chain == successful deliveries counted by the handler; the executor's token1 balance always equals initial inventory + booked profit; the executor never holds token0 after a sequence; stored reserves always equal the last delivered Sync |

Full output of the reference run: [`analysis/forge-test-output.txt`](analysis/forge-test-output.txt).

Two fuzz counterexamples were found and fixed **in the tests** during
development (the contracts were not touched): the fuzzer's address
dictionary contains Multicall3 (`0x7109709E…`) and precompiles such as
`0x0C`, which reject plain ETH transfers — the owner-withdraw properties
now scope their recipient to ordinary addresses, which is the behaviour
being claimed.

## Static analysis — Slither 0.11.6

Command (Foundry project, dependencies and test doubles filtered out of
the report):

```bash
slither . --filter-paths "lib/|test/"
```

Raw results: [`analysis/slither-report.json`](analysis/slither-report.json)
(machine-readable) and [`analysis/slither-output.txt`](analysis/slither-output.txt).

**Outcome: 19 findings — 0 High, 3 Medium, 10 Low, 6 Informational**
(21 contracts analysed, 102 detectors). We do not claim zero findings;
the dispositions are:

### Medium (3)

- **`divide-before-multiply` ×1 — `GapHunterReactive.react`.** The
  flagged lines are the basis-point fixed-point sizing
  (`amountIn = buyReserve1 * tradeFractionBps / 10_000`) and the
  minimum-profit comparison. Truncation is at most 1 wei of trade size,
  and the RSC's estimate is advisory: the executor re-derives
  profitability from live reserves with multiply-then-divide
  `amountOut` math inside the callback and reverts if the round trip is
  not profitable. A rounding discrepancy can cause a skipped or
  reverted arbitrage — never a losing trade. Accepted.
- **`unused-return` ×2 — `GapHunterExecutor.executeArb`.** The ignored
  values are the third return of `getReserves()`
  (`blockTimestampLast`) for the two pools. Deliberate: the executor's
  cooldown is specified on `block.timestamp` directly (Base Sepolia
  guidance is to use timestamps, not block-derived values), so the
  pairs' last-update timestamps are not needed. Accepted, by design.

### Low (10)

- **`missing-zero-check` ×5** — constructor `poolA_`/`poolB_`,
  `setExecutor`'s `executor_`, and the `to_` of both owner withdraw
  helpers. All are deployer/owner-supplied parameters on a fixed,
  on-chain-verified deployment; a zero pool would make the executor's
  pair calls revert (no funds move), and withdrawing to the zero
  address is an owner choosing to burn their own funds. Accepted for
  this deployment; noted for any reuse.
- **`reentrancy-benign` ×1 — `executeArb`.** The nonce and timestamp
  are written **before** any external call; re-entry would have to come
  through the callback proxy (the only address `onlyServiceProvider`
  admits), present the RSC as sender (`onlyCallbackSender`), and pass
  the already-incremented nonce and the cooldown — so the flagged
  post-call counter writes (`totalProfit`, `arbsExecuted`) are not
  reachable re-entrantly. Accepted.
- **`reentrancy-events` ×3** — events emitted after external calls in
  `react`, `executeArb` and `rescue`. Event ordering only; no state
  depends on it. Accepted.
- **`timestamp` ×1 — `executeArb`.** The cooldown's use of
  `block.timestamp` is the design (see above); the default 60-second
  window dwarfs any sequencer timestamp drift, and the value at stake
  is rate-limiting, not fund custody. Accepted.

### Informational (6)

- **`low-level-calls` ×2** — the owner withdraw helpers use
  `address.call` and check the result with `require(ok)`. The standard
  pattern for native withdrawals.
- **`unindexed-event-address` ×2** — `ExecutorSet` and `Rescued` event
  address parameters are not indexed. Cosmetic for log filtering.
- **`naming-convention` ×2** — two variables in `PingPong.sol`, a demo
  contract that is not part of the trading path.

### Aderyn

Aderyn is **not** included: Cyfrin has retired the tool and withdrawn
the official CLI downloads (checked 2026-11-28 — the release installer
itself prints that installation downloads have been withdrawn, and no
release ships a binary). Rather than fetch a retired security tool
from an unofficial mirror, this report relies on Slither plus the test
suite above.

## Source verification

Both Base-leg contracts are **Sourcify-verified with an exact match**
(Reactive Lasna RSC and Base Sepolia executor); commands and URLs are
in [`VERIFICATION.md`](VERIFICATION.md), and
`script/verify-deployment.sh` byte-compares the deployed bytecode
against a fresh compile.

## Scope notes

- `MockERC20`'s open `mint` is by design: it is the testnet demo token,
  documented as valueless in its own source. It is not a production
  asset contract.
- The analysis above covers the contracts as deployed. The live
  deployment and its evidence predate this document; nothing was
  redeployed for it — this is tests and analysis only.
