# GapHunter — FINAL BUIDL content (for the parent to apply to https://dorahacks.io/buidl/51863)

Prepared 2026-11-26. Event: Reactive Omni Buildathon, track **Every Second Counts**.
Status: BUIDL already submitted / Under Review — this replaces the description
(the current page still shows the old 20-run figures) and the demo video link
(new video file: `demo/gaphunter-demo.mp4`, 120 s, 1280×720 — upload to YouTube
unlisted and swap the link, same as before). All other fields (title, track,
contacts) stay as they are.

**Title:** GapHunter — a reactive cross-pool arbitrage sentinel

**Repository:** https://github.com/Scxfdarpo/gaphunter

**Dashboard:** https://scxfdarpo.github.io/gaphunter/

---

## Description (paste-ready)

Two Uniswap V2 pools for the same token pair drift apart in price all the
time. Closing that gap normally takes an off-chain bot: a server watching
both pools, signing transactions, hoping it stays up. GapHunter removes the
bot. A Reactive Smart Contract on Lasna watches both pools itself, and the
moment the spread is worth taking, it orders the arbitrage on-chain — no
server, no keeper, no human trigger. The same system runs on **two origin
chains** (Base Sepolia and Unichain Sepolia), each with its own reactive
contract on Lasna and its own executor.

- **Execution** — the complete event → react → callback loop ran live on
  public testnets **320 times: 300 recorded runs on Base Sepolia and 20 on
  Unichain Sepolia — every one executed, 0 refused, 0 failed.** Base latency
  p50 1 s / p95 2 s; Unichain p50 2 s / p95 3 s. Profit, from the executors'
  own on-chain counters: **+952,227.72 GTB** (Base) and **+36,482.76 GTA**
  (Unichain), reconciled against the per-run ledger in the repo (the one
  extra on-chain execution from a host-restart window is documented in the
  README, with its hash). A 2-second polling keeper baseline over runs 3–50
  **missed 5 of 48 gaps entirely** — the reactive loop had already closed
  them. Nothing is simulated; every run carries its whale / react /
  callback transaction hashes.
- **Integration** — the reactive contract *is* the strategy: it holds both
  pools' prices, applies the fee-adjusted spread threshold, sizes the trade
  from live pool depth, and estimates round-trip profit before spending a
  callback. The executor re-verifies profitability against live reserves
  inside the callback and reverts if the gap is gone. Remove Reactive and
  the system does nothing at all. Lasna sits in the middle of both legs.
- **Usefulness** — cross-venue price gaps are the canonical latency problem
  in DeFi; closing them realigns prices for everyone. The pattern
  generalises to any V2-style pair on any supported origin chain — the
  Unichain leg was added by redeploying the same contracts unchanged. The
  README is honest about scope: a 3,000-sample scan of Base mainnet found
  zero net-profitable gaps after fees, so this proves the pattern, not a
  mainnet edge.
- **Craft** — Foundry repo, **17/17 tests** (full-loop suite against real
  constant-product pools + 12 guard tests), both Base-leg contracts
  **Sourcify-verified with an exact match**, a live dashboard that reads
  reserves and executor counters straight from RPC, reproducible deployment
  scripts for both chains, and a complete evidence trail (run ledgers,
  polling baseline, driver logs) in the repo.

## Deployed contracts

| Contract | Chain | Address |
| --- | --- | --- |
| GapHunterReactive (Base leg) | Reactive Lasna (5318007) | 0x33BB79402a0802bE06D8b9F2b6171e80e54B3222 |
| GapHunterExecutor (Base leg) | Base Sepolia (84532) | 0x986249121a4453294A68f6c7Cbc250Db6d30bF63 |
| Pair A / Pair B | Base Sepolia | 0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3 / 0x8e62F00356C75791570182bB1A412BC4129f387a |
| GTA (token0) / GTB (token1) | Base Sepolia | 0x2250E6CAd8e9233eeb8f97434fA8aD2Cde071B1b / 0xD6a779b928d8F284C7A30347a8302e3E0579aA20 |
| GapHunterReactive #2 (Unichain leg) | Reactive Lasna (5318007) | 0xD6a779b928d8F284C7A30347a8302e3E0579aA20 |
| GapHunterExecutor #2 | Unichain Sepolia (1301) | 0xBD1E78903d4703D7C1Ec1B044b2F807778CE5C53 |
| Pair A / Pair B | Unichain Sepolia | 0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3 / 0x8e62F00356C75791570182bB1A412BC4129f387a |
| Callback proxy | Unichain Sepolia | 0x775c9B990ADe401060B78D0e98684eEf8d2466C1 |

Note: factory A and GapHunterReactive share the address 0x33BB79402a… on
their respective chains because the same deployer wallet deployed both at
the same nonce on different chains — expected, not an error. The Unichain
factories/pairs likewise mirror the Base addresses (same nonce sequence,
CREATE2 pair derivation).

## Representative full-loop transaction hashes

- **First run (Base, 2026-11-24):** whale
  0x4a006218f4512ae3f8bc27b1841baf6f4d0a52da9b14cf522b7f6a33d2376494 →
  react (Lasna) 0xcf1dc1b75a912757d83d9843a16146ad9281bc656ac11beeb199d73195af89ab →
  callback 0x52a56282428e1da07843aee47a8a4a470e9f1e44a6c46fa47d97c7ca2da48d9a
  (≈1 s, +3,041.01 GTB)
- **Mid-batch, run 150 (Base):** whale
  0x6ff1eed7eab09ec4655cceadb6ea0ae7d9e4d6571c9b5d5f5518d5e6703d3f1c →
  react 0x50d4f2f53281afb1c810872a9f8a95f03d3abad53d89d78722427d0296439807 →
  callback 0xa368f703f727c6f2fb35e6859d8087e9ad7d51221ba259773519a5d0adb637da
  (1 s, +1,495.10 GTB)
- **Run 300 (Base, 2026-11-26):** whale
  0xe3c40d96fcdde2395dcdb4ef5ca5c4955f962daa940d3a5a3d835716b81ffddb →
  react 0xf035e00d66d3ff9d61878de3575e218a9324bdd20b3383665cf68fbe7cdfb862 →
  callback 0x18d752f8316be71b798f7c4667382dea6ab0a6b200e3e2679548a87a76c32e5c
  (1 s, +1,726.32 GTB)
- **Unichain run 1:** whale
  0xad1018527828fce0ca2b0948d4c584913f3a8ddfe7b49d8cd41adba79703d4d9 →
  react 0x432892990f914df0b62be17eee4c65cb52f6eb3fc08ac53507c0ec4e481d848d →
  callback 0x802d39fb0b7913be09cf66caac6f01ce18761f57e36e719c3825c5a6e45b7938
  (3 s, +3,083.51 GTA)
- **Unichain run 20:** whale
  0x550a29624377505ba5617e1dc75b9bc45a4e02bde1296d82b93928e1f20299c6 →
  react 0x5f606301ce8572f37f47adfad50371a9b751d3b7294bbbe8fa4cd6707e54295e →
  callback 0x391d75dfc3b9280619f0603fb4d315fe7c7cd027c6f0f41f767d145beeb5b7e5
  (3 s, +962.22 GTA)

## Verification links

- Sourcify exact match, executor (Base Sepolia):
  https://repo.sourcify.dev/84532/0x986249121a4453294A68f6c7Cbc250Db6d30bF63
- Sourcify exact match, reactive (Lasna):
  https://repo.sourcify.dev/5318007/0x33BB79402a0802bE06D8b9F2b6171e80e54B3222
- Live dashboard: https://scxfdarpo.github.io/gaphunter/
- Run ledgers: `evidence/runs.json` (Base, 300 runs),
  `evidence/unichain-runs.json` (Unichain, 20 runs),
  `evidence/baseline.md` (polling baseline, runs 3–50) — all in the repo.

## Organizer questionnaire — answers for the previously blank fields

1. **Is this your first time building with Reactive Network?**
   Yes. GapHunter is our first Reactive build. We started from the
   reactive-lib demos, initially on the legacy API that the default
   branches still carry, then moved to the current Omni API
   (`reactive-lib-omni`) — the contracts here are written against the
   Omni subscription/callback model from the start of the event window.

2. **Is this your first time writing smart contracts?**
   *(Flag: closest honest answer based on project history — the account's
   prior hackathon/bounty work this season was TypeScript, not Solidity;
   these are the first contracts we have deployed, verified and operated
   live. If the user has earlier personal Solidity experience we don't
   know about, adjust before submitting.)*
   These are the first smart contracts we have taken all the way —
   written, deployed to live testnets, source-verified, and operated
   across 320 live executions. The two GapHunter contracts, the demo
   tokens and the Uniswap V2 venue deployments were all produced during
   this event window with Foundry.

3. **What was the hardest part of the build?**
   The operational economics of the reactive contract. An RSC pays for
   every reaction in lREACT — we measured ≈0.0448 lREACT per loop, about
   7.5× our first estimate — and when its balance reached zero mid-batch
   it accrued debt to the system contract and event deliveries silently
   stopped; topping up alone does not clear it, the debt has to be repaid
   through the contract's owner `withdraw` path. Keeping a 300-run batch
   alive through that, plus public-RPC rate limits and lagging nodes, was
   the real work. The arbitrage logic itself was the easy part.

4. **How did you hear about this hackathon?**
   Through DoraHacks. We surveyed the platform's open hackathons and
   chose this one for its published rubric, its testnet-only scope, and
   the "Lasna in the middle" design constraint.
