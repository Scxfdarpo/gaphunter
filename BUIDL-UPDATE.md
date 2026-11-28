# BUIDL update — craft/test upgrade (for the parent to apply to https://dorahacks.io/buidl/51863)

Prepared 2026-11-28. **Scope: one paragraph.** The BUIDL description
currently live is the text in `BUIDL-FINAL.md`; this update replaces
only its **Craft** bullet with the one below. Nothing else changes —
title, track, links, deployed-contract table, transaction hashes and
every evidence figure (320 runs, profits, baseline) stay exactly as
they are. No contracts were modified or redeployed for this upgrade;
it is tests, static analysis and documentation only (repo commit adds
`test/GapHunterFuzz.t.sol`, `test/GapHunterProperties.t.sol`,
`test/GapHunterInvariant.t.sol`, `SECURITY.md`, `analysis/`).

## Find this exact text

- **Craft** — Foundry repo, **17/17 tests** (full-loop suite against real
  constant-product pools + 12 guard tests), both Base-leg contracts
  **Sourcify-verified with an exact match**, a live dashboard that reads
  reserves and executor counters straight from RPC, reproducible deployment
  scripts for both chains, and a complete evidence trail (run ledgers,
  polling baseline, driver logs) in the repo.

## Replace it with this exact text

- **Craft** — Foundry repo, **66/66 tests passing**: the full-loop suite
  against real constant-product pools and 12 guard tests, **48
  fuzz/property tests at 256 runs each** — including a pricing-model
  equivalence property (the executor executes if and only if the
  constant-product model says the round trip is profitable, and books
  exactly the modelled profit) and guard modifiers fuzzed over arbitrary
  callers, nonces and timestamps — plus a **12-property invariant
  campaign (256 runs × 500 calls = 128,000 stateful calls)** proving
  nonce discipline and the executor's balance identity (token1 held ==
  inventory + booked profit, always). **Slither static analysis** is
  published in the repo with an honest disposition of every finding
  (0 High, 3 Medium, 10 Low, 6 Informational — the Mediums are the
  basis-point sizing truncation and the deliberately unused
  `blockTimestampLast` returns; see `SECURITY.md`). Both Base-leg
  contracts **Sourcify-verified with an exact match**, a live dashboard
  that reads reserves and executor counters straight from RPC,
  reproducible deployment scripts for both chains, and a complete
  evidence trail (run ledgers, polling baseline, driver logs) in the
  repo.

## Numbers behind the paragraph (all from tool runs on the repo, 2026-11-28)

- `forge test`: 5 suites, **66 tests passed, 0 failed** (full output:
  `analysis/forge-test-output.txt` in the repo).
- Fuzz: 48 property tests × 256 runs = 12,288 randomized cases.
- Invariants: 12 properties, 256 runs × 500-call sequences = 128,000
  handler calls, 0 reverts (default `forge test` configuration).
- Slither 0.11.6, 102 detectors, 21 contracts in scope: 19 findings —
  0 High / 3 Medium / 10 Low / 6 Informational (raw report:
  `analysis/slither-report.json`). Aderyn is not reported: Cyfrin has
  retired it and withdrawn the official downloads (verified
  2026-11-28), so no Aderyn claim is made anywhere.
