#!/usr/bin/env python3
"""Recover runs 51, 52, 54: their full loops executed on-chain but the
driver recorded 'error' after an eth_getBlockByNumber HTTP 408 timeout
during bookkeeping. Rebuild the records from the ArbSignalled (Lasna)
and ArbExecuted (Base Sepolia) logs plus the whale Swap log, verify the
ArbExecuted profit matches the recorded GTB balance delta, then update
runs_partial.json + runs.json and recompute the stats block.
Read-only on-chain; the private key is never used here.
"""
import json, time, urllib.request, os, sys

ROOT = "/home/hatch/workspace/dorahacks/reactive-omni/gaphunter/evidence"
BASE_URLS = ["https://sepolia.base.org", "https://base-sepolia.drpc.org"]
LASNA = "https://lasna-rpc.rnk.dev"
WALLET = "0xdb75249615a23133fD10b8e96B9220EF1B950B5d"
RSC = "0x33BB79402a0802bE06D8b9F2b6171e80e54B3222"
EXEC = "0x986249121a4453294A68f6c7Cbc250Db6d30bF63"
PAIR_A = "0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3"
PAIR_B = "0x8e62F00356C75791570182bB1A412BC4129f387a"
SIG_SIGNAL = "0x971e555bdd0b3416d51acae08cb13c3bef39bc8342526a9880879bf1375d6c6a"
SIG_EXEC = "0xcbc28a3fde15a46119e8269891df047f8d565acbacef6df53b535b4c3eb7f6d7"
SIG_SWAP = "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822"
E18 = 10**18

sys.path.insert(0, ROOT)
from batch_driver300 import compute_stats  # noqa: E402  (pure function; no main run)

def rpc(urls, method, params, tries=10):
    last = None
    for i in range(tries):
        url = urls[i % len(urls)] if isinstance(urls, list) else urls
        try:
            req = urllib.request.Request(url, data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                headers={"Content-Type": "application/json",
                         "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"})
            with urllib.request.urlopen(req, timeout=25) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(str(out["error"])[:160])
            return out["result"]
        except Exception as e:
            last = e
            time.sleep(min(1.5 * (i + 1), 8))
    raise RuntimeError(f"rpc {method} failed: {last}")

def block_ts(n):
    b = rpc(BASE_URLS, "eth_getBlockByNumber", [hex(n), False])
    return int(b["timestamp"], 16)

def get_logs(urls, address, lo, hi, topics, chunk=120):
    out = []
    b = lo
    while b <= hi:
        e = min(b + chunk - 1, hi)
        out += rpc(urls, "eth_getLogs", [{"address": address, "fromBlock": hex(b),
                                          "toBlock": hex(e), "topics": topics}])
        b = e + 1
    return out

def words(log):
    d = log["data"][2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]

def recover(run_no, partial):
    rec = partial[run_no]
    nonce = rec["expectedNonce"]
    prev = partial[run_no - 1]
    nxt = partial[run_no + 1]
    lo = prev["callbackBlock"]
    hi = nxt["whaleBlock"]
    topic_nonce = "0x" + format(nonce, "064x")

    exec_logs = get_logs(BASE_URLS, EXEC, lo, hi, [SIG_EXEC, topic_nonce])
    assert len(exec_logs) == 1, f"run {run_no}: {len(exec_logs)} ArbExecuted logs for nonce {nonce}"
    el = exec_logs[0]
    ew = words(el)
    cb_block = int(el["blockNumber"], 16)
    profit_raw = ew[4]

    sig_logs = get_logs(LASNA, RSC, prev["reactLasnaBlock"], nxt["reactLasnaBlock"],
                        [SIG_SIGNAL, topic_nonce], chunk=400)
    assert len(sig_logs) == 1, f"run {run_no}: {len(sig_logs)} ArbSignalled logs for nonce {nonce}"
    sl = sig_logs[0]
    sw = words(sl)

    wal_topic = "0x" + WALLET[2:].lower().rjust(64, "0")
    whale = None
    for pair in (PAIR_A, PAIR_B):
        logs = get_logs(BASE_URLS, pair, lo, cb_block, [SIG_SWAP, wal_topic, wal_topic])
        if logs:
            assert len(logs) == 1, f"run {run_no}: {len(logs)} whale swaps on {pair}"
            whale = (pair, logs[0])
            break
    assert whale, f"run {run_no}: whale swap not found"
    whale_pair, wl = whale
    whale_block = int(wl["blockNumber"], 16)
    ww = words(wl)
    # Swap data: amount0In, amount1In, amount0Out, amount1Out
    if ww[1] > 0:
        token_in, amt_in, amt_out = "GTB", ww[1], ww[2]
    else:
        token_in, amt_in, amt_out = "GTA", ww[0], ww[3]

    origin_ts = block_ts(whale_block)
    cb_ts = block_ts(cb_block)
    delta = rec["gtbAfter"] - rec["gtbBefore"]
    assert abs(profit_raw / E18 - delta) < 1e-6, \
        f"run {run_no}: profit {profit_raw / E18} != balance delta {delta}"

    rec.update({
        "outcome": "executed",
        "whaleTx": wl["transactionHash"], "whaleBlock": whale_block, "originTs": origin_ts,
        "whalePool": "A" if whale_pair == PAIR_A else "B",
        "whaleTokenIn": token_in, "whaleAmountIn": amt_in // E18,
        "whaleAmountOut": amt_out / E18,
        "reactTx": sl["transactionHash"], "reactLasnaBlock": int(sl["blockNumber"], 16),
        "signalSpreadBps": sw[3], "signalAmountInGTB": sw[2] / E18,
        "signalPoolBuy": hex(sw[0]), "signalPoolSell": hex(sw[1]),
        "callbackTx": el["transactionHash"], "callbackBlock": cb_block, "callbackTs": cb_ts,
        "latencySec": cb_ts - origin_ts, "latencyBlocks": cb_block - whale_block,
        "profitGTB": profit_raw / E18, "profitRaw": str(profit_raw),
        "balanceDeltaGTB": delta,
        "recoveredFromError": rec.pop("error", None),
        "recoveredNote": ("Driver recorded 'error' (eth_getBlockByNumber HTTP 408) during "
                          "bookkeeping after the whale had landed; the full loop executed "
                          "on-chain. Record rebuilt from ArbSignalled/ArbExecuted/Swap logs; "
                          "ArbExecuted profit matches the recorded executor GTB balance delta."),
    })
    print(f"run {run_no}: recovered nonce {nonce} profit {profit_raw / E18:.6f} GTB "
          f"latency {cb_ts - origin_ts}s whale {wl['transactionHash'][:16]}..")
    return rec

def main():
    partial_list = json.load(open(os.path.join(ROOT, "runs_partial.json")))
    partial = {r["run"]: r for r in partial_list}
    for n in (51, 52, 54):
        recover(n, partial)
    new_partial = [partial[k] for k in sorted(partial)]
    tmp = os.path.join(ROOT, "runs_partial.json.tmp")
    json.dump(new_partial, open(tmp, "w"), indent=2)
    os.replace(tmp, os.path.join(ROOT, "runs_partial.json"))

    doc = json.load(open(os.path.join(ROOT, "runs.json")))
    runs = {r["run"]: r for r in doc["runs"]}
    for n in (51, 52, 54):
        runs[n] = partial[n]
    doc["runs"] = [runs[k] for k in sorted(runs)]
    doc["stats"] = compute_stats(doc["runs"])
    tmp = os.path.join(ROOT, "runs.json.tmp")
    json.dump(doc, open(tmp, "w"), indent=2)
    os.replace(tmp, os.path.join(ROOT, "runs.json"))
    print(json.dumps(doc["stats"], indent=2))

if __name__ == "__main__":
    main()
