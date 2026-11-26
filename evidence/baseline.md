# Polling-keeper baseline vs the reactive loop

During the 2026-11-25 batch, a script polled both pairs' `getReserves`
every 2 seconds (one batched JSON-RPC request per tick, 2,209 usable
samples logged to `poll.jsonl`). For each whale swap we record the
first poll sample at or after the whale's block whose spot spread is
>= 150 bps — the moment a polling keeper would first *detect* the
gap — and compare it with the reactive loop's *end-to-end execution*
time (whale block timestamp -> callback block timestamp).

**Coverage: the poller ran during runs 3–50 only.** The table below
covers exactly those 48 runs. Runs 51–300 of the batch have no polling
baseline and none is claimed for them.

| Run | Polling detection lag (s) | Reactive execution latency (s) |
| --- | --- | --- |
| 3 | 0.18 | 1 |
| 4 | 0.0 | 1 |
| 5 | 1.92 | 1 |
| 6 | **missed** | 1 |
| 7 | 0.46 | 1 |
| 8 | 0.62 | 1 |
| 9 | 4.93 | 1 |
| 10 | 0.35 | 1 |
| 11 | 0.84 | 1 |
| 12 | 0.06 | 1 |
| 13 | 0.0 | 1 |
| 14 | **missed** | 1 |
| 15 | 0.46 | 1 |
| 16 | 0.22 | 1 |
| 17 | 4.28 | 1 |
| 18 | 0.0 | 1 |
| 19 | 0.0 | 1 |
| 20 | 0.0 | 1 |
| 21 | 1.37 | 1 |
| 22 | 3.36 | 1 |
| 23 | 0.6 | 1 |
| 24 | 0.19 | 1 |
| 25 | 0.0 | 1 |
| 26 | 1.02 | 1 |
| 27 | 1.38 | 1 |
| 28 | 2.89 | 2 |
| 29 | 0.0 | 1 |
| 30 | 1.56 | 2 |
| 31 | **missed** | 1 |
| 32 | 0.43 | 1 |
| 33 | 0.3 | 1 |
| 34 | 1.34 | 1 |
| 35 | **missed** | 1 |
| 36 | 1.19 | 2 |
| 37 | 0.0 | 1 |
| 38 | 0.85 | 1 |
| 39 | 0.0 | 2 |
| 40 | 0.0 | 2 |
| 41 | **missed** | 2 |
| 42 | 0.0 | 1 |
| 43 | 0.0 | 1 |
| 44 | 5.25 | 2 |
| 45 | 0.54 | 1 |
| 46 | 1.13 | 1 |
| 47 | 0.51 | 2 |
| 48 | 0.19 | 1 |
| 49 | 1.23 | 2 |
| 50 | 3.57 | 1 |

Polling detection lag (detected runs only): median 0.46s, max 5.25s over 43 of 48 runs.
Polling keeper MISSED 5 of 48 runs entirely: runs 6, 14, 31, 35, 41.
Reactive execution latency over the same 48 runs: p50 1s, p95 2s (full 300-run batch: p50 1s, p95 2s).

Reading of the comparison: for wide gaps the poller's detection lag is
bounded by its 2-second tick, so it 'sees' the gap about as fast as the
reactive contract reacts — but detection is all it does. A polling
keeper must then sign and land its own transaction (at least one more
block, plus gas bidding and nonce management, on a server that must
stay up), whereas the reactive numbers above are the full loop: origin
event -> Lasna reaction -> callback executed on Base Sepolia, with no
server, no signing key online, and nothing to keep alive.

The misses are the sharper result. On the thin 'flip' runs (signal
spread ~665-670 bps), the reactive loop executed about 1 second after
the whale swap and knocked the spread to 147-152 bps — below the
150 bps action threshold — before the poller's next tick. The first
post-whale poll samples for runs 6 and 14 (at +5.9s and +3.8s) already
show 149 and 147 bps: at polling cadence, those two opportunities
never existed. Runs 31, 35 and 41 were missed the same way. A faster
poller narrows this gap only by paying more RPC load forever; the
reactive contract pays nothing while it waits.

Caveat: block timestamps on Base Sepolia have 1-second granularity, so
sub-second differences are not resolvable from chain data; the poller
timestamps are wall-clock at sample completion.
