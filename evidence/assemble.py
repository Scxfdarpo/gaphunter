#!/usr/bin/env python3
"""Assemble evidence/runs.json (original runs 1-2 + batch runs 3..N) and
evidence/baseline.md (polling-keeper comparison from poll.jsonl)."""
import json, statistics, os

ROOT = "/home/hatch/workspace/dorahacks/reactive-omni/gaphunter/evidence"
E18 = 1e18

ORIGINALS = [
    {
        "run": 1,
        "date": "2026-11-24",
        "whaleTx": "0x4a006218f4512ae3f8bc27b1841baf6f4d0a52da9b14cf522b7f6a33d2376494",
        "whalePool": "B", "whaleTokenIn": "GTB", "whaleAmountIn": 100000,
        "whaleBlock": 62994276, "whaleBlockTs": 1795520724,
        "originTx": "0x77c4b3e8989d213932832bc324b9e23776dcb42a6d5bb4e5d133a241ed07ad9f",
        "originNote": "The RSC was deployed after the pairs were seeded and had not yet seen a Sync from pool A, so a 1,000 GTB poke swap on pool A armed the loop; latency is measured from the poke (the triggering origin event).",
        "originBlock": 62995152, "originTs": 1795520899,
        "reactTx": "0xcf1dc1b75a912757d83d9843a16146ad9281bc656ac11beeb199d73195af89ab",
        "reactLasnaBlock": 9134595,
        "callbackTx": "0x52a56282428e1da07843aee47a8a4a470e9f1e44a6c46fa47d97c7ca2da48d9a",
        "callbackBlock": 62995159, "callbackTs": 1795520900,
        "latencySec": 1, "latencyBlocks": 7,
        "gtbBefore": 500000.0, "gtbAfter": 503041.005514,
        "profitGTB": 3041.005514, "profitRaw": "3041005513650676434839",
        "signalAmountInGTB": 20020.0,
        "outcome": "executed",
    },
    {
        "run": 2,
        "date": "2026-11-24",
        "whaleTx": "0x65ba04618c8ec579ec65271ef1bdb69a3d6d60739ee46be6d625f111ceb72254",
        "whalePool": "B", "whaleTokenIn": "GTB", "whaleAmountIn": 100000,
        "whaleBlock": 62995873, "whaleBlockTs": 1795521043,
        "originTx": "0x65ba04618c8ec579ec65271ef1bdb69a3d6d60739ee46be6d625f111ceb72254",
        "originBlock": 62995873, "originTs": 1795521043,
        "reactTx": "0xdfed9b8a354cb7c76018bc09d84b692d1c9ba4bd6cef3c03eb107372d3a3342d",
        "reactLasnaBlock": 9134732,
        "reactNote": "React tx hash recovered on 2026-11-25 by searching the RSC's ArbSignalled logs (nonce 2) on Lasna; it matches the RSC's lastArbBlock at the time (9134732). Signal spread was 3280 bps, amountIn 20,420.40 GTB, estimated profit equal to realised profit.",
        "callbackTx": "0x81d3308961347438675a4ac26a2d17c13142accb72cbb5cc7faa2fdefc764ffc",
        "callbackBlock": 62995880, "callbackTs": 1795521044,
        "latencySec": 1, "latencyBlocks": 7,
        "gtbBefore": 503041.005514, "gtbAfter": 508469.675457,
        "profitGTB": 5428.669943, "profitRaw": "5428669942866131543173",
        "signalAmountInGTB": 20420.4, "signalSpreadBps": 3280,
        "outcome": "executed",
    },
]

def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)

def main():
    batch = json.load(open(os.path.join(ROOT, "runs_partial.json")))
    runs = ORIGINALS + batch
    runs.sort(key=lambda r: r["run"])

    executed = [r for r in runs if r.get("outcome") == "executed"]
    refused = [r for r in runs if r.get("outcome") == "refused"]
    other = [r for r in runs if r.get("outcome") not in ("executed", "refused")]
    lat = [r["latencySec"] for r in executed if r.get("latencySec") is not None]
    lat_blocks = [r["latencyBlocks"] for r in executed if r.get("latencyBlocks") is not None]
    total_profit = sum(r.get("profitGTB", 0.0) for r in executed)
    batch_profit = sum(r.get("profitGTB", 0.0) for r in executed if r["run"] >= 3)

    stats = {
        "totalRuns": len(runs),
        "executed": len(executed),
        "refused": len(refused),
        "otherOutcomes": [{"run": r["run"], "outcome": r.get("outcome")} for r in other],
        "latencySecP50": pct(lat, 50),
        "latencySecP95": pct(lat, 95),
        "latencySecMin": min(lat) if lat else None,
        "latencySecMax": max(lat) if lat else None,
        "latencyBlocksMedian": statistics.median(lat_blocks) if lat_blocks else None,
        "totalProfitGTB": round(total_profit, 6),
        "batchProfitGTB": round(batch_profit, 6),
        "originalProfitGTB": 8469.675457,
    }

    out = {
        "project": "GapHunter — reactive cross-pool arbitrage sentinel",
        "generatedFrom": "Live runs on Base Sepolia (84532) + Reactive Lasna (5318007). Runs 1-2: 2026-11-24 (see README Evidence). Runs 3+: 2026-11-25 batch.",
        "contracts": {
            "reactiveLasna": "0x33BB79402a0802bE06D8b9F2b6171e80e54B3222",
            "executorBaseSepolia": "0x986249121a4453294A68f6c7Cbc250Db6d30bF63",
            "pairA": "0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3",
            "pairB": "0x8e62F00356C75791570182bB1A412BC4129f387a",
        },
        "stats": stats,
        "runs": runs,
    }
    json.dump(out, open(os.path.join(ROOT, "runs.json"), "w"), indent=2)

    # ---- baseline comparison ----
    samples = []
    for line in open(os.path.join(ROOT, "poll.jsonl")):
        try:
            s = json.loads(line)
        except Exception:
            continue
        if "spreadBps" in s:
            samples.append(s)
    rows = []
    batch_sorted = sorted(batch, key=lambda r: r["run"])
    for i, r in enumerate(batch_sorted):
        if r.get("outcome") not in ("executed", "refused"):
            continue
        wb, ots = r["whaleBlock"], r["originTs"]
        # Detection window ends at the next run's whale (or +30s): a sample
        # after that belongs to the next gap, not this one.
        nxt = batch_sorted[i + 1]["originTs"] if i + 1 < len(batch_sorted) else ots + 30
        window_end = min(nxt, ots + 30)
        det = None
        for s in samples:
            if s["block"] >= wb and s["t"] <= window_end and s["spreadBps"] >= 150:
                det = s
                break
        # Sequencer block timestamps run slightly ahead of the poller's wall
        # clock (observed skew < 1s), so clamp small negatives to 0.
        det_lag = max(0.0, round(det["t"] - ots, 2)) if det else None
        rows.append((r["run"], det_lag, r.get("latencySec")))
    det_lags = [d for _, d, _ in rows if d is not None]
    missed = [run_no for run_no, d, _ in rows if d is None]
    lines = []
    lines.append("# Polling-keeper baseline vs the reactive loop")
    lines.append("")
    lines.append("During the 2026-11-25 batch (runs 3+), a script polled both pairs'")
    lines.append("`getReserves` every 2 seconds (one batched JSON-RPC request per tick,")
    lines.append(f"{len(samples)} usable samples logged to `poll.jsonl`). For each whale swap we")
    lines.append("record the first poll sample at or after the whale's block whose spot")
    lines.append("spread is >= 150 bps — the moment a polling keeper would first *detect*")
    lines.append("the gap — and compare it with the reactive loop's *end-to-end execution*")
    lines.append("time (whale block timestamp -> callback block timestamp).")
    lines.append("")
    lines.append("| Run | Polling detection lag (s) | Reactive execution latency (s) |")
    lines.append("| --- | --- | --- |")
    for run_no, d, lat_s in rows:
        lines.append(f"| {run_no} | {d if d is not None else '**missed**'} | {lat_s if lat_s is not None else 'n/a'} |")
    lines.append("")
    if det_lags:
        lines.append(f"Polling detection lag (detected runs only): median {statistics.median(det_lags):.2f}s, "
                     f"max {max(det_lags):.2f}s over {len(det_lags)} of {len(rows)} runs.")
    if missed:
        lines.append(f"Polling keeper MISSED {len(missed)} of {len(rows)} runs entirely: "
                     f"runs {', '.join(str(m) for m in missed)}.")
    if lat:
        lines.append(f"Reactive execution latency (all {len(lat)} executed runs incl. 2026-11-24): "
                     f"p50 {pct(lat, 50):.0f}s, p95 {pct(lat, 95):.0f}s.")
    lines.append("")
    lines.append("Reading of the comparison: for wide gaps the poller's detection lag is")
    lines.append("bounded by its 2-second tick, so it 'sees' the gap about as fast as the")
    lines.append("reactive contract reacts — but detection is all it does. A polling")
    lines.append("keeper must then sign and land its own transaction (at least one more")
    lines.append("block, plus gas bidding and nonce management, on a server that must")
    lines.append("stay up), whereas the reactive numbers above are the full loop: origin")
    lines.append("event -> Lasna reaction -> callback executed on Base Sepolia, with no")
    lines.append("server, no signing key online, and nothing to keep alive.")
    lines.append("")
    lines.append("The misses are the sharper result. On the thin 'flip' runs (signal")
    lines.append("spread ~665-670 bps), the reactive loop executed about 1 second after")
    lines.append("the whale swap and knocked the spread to 147-152 bps — below the")
    lines.append("150 bps action threshold — before the poller's next tick. The first")
    lines.append("post-whale poll samples for runs 6 and 14 (at +5.9s and +3.8s) already")
    lines.append("show 149 and 147 bps: at polling cadence, those two opportunities")
    lines.append("never existed. A faster poller narrows this gap only by paying more")
    lines.append("RPC load forever; the reactive contract pays nothing while it waits.")
    lines.append("")
    lines.append("Caveat: block timestamps on Base Sepolia have 1-second granularity, so")
    lines.append("sub-second differences are not resolvable from chain data; the poller")
    lines.append("timestamps are wall-clock at sample completion.")
    open(os.path.join(ROOT, "baseline.md"), "w").write("\n".join(lines) + "\n")
    print(json.dumps(stats, indent=2))
    print("baseline rows:", rows)

if __name__ == "__main__":
    main()
