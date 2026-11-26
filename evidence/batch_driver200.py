#!/usr/bin/env python3
"""GapHunter batch driver, extension to 200 total runs (runs 21..200).

Same mechanics as batch_driver.py (adaptive alternating whale, Lasna
ArbSignalled watch, Base Sepolia ArbExecuted verification via executor
GTB balance delta), plus:
- per-run checkpointing into BOTH evidence/runs_partial.json and
  evidence/runs.json (record appended + stats recomputed, atomic write)
- evidence/batch200_progress.txt updated after every run
- funds watch: RSC lREACT balance recorded per run; auto top-up of the
  RSC from the wallet's lREACT, and (if that runs out) an lREACT purchase
  via the Reactive faucet contract (send Sepolia ETH -> 100 lREACT/ETH);
  executor callback-ETH auto top-up from the wallet. A HardStop is
  raised (and recorded in the progress file) only when funds are
  genuinely exhausted.
The private key is loaded from evm-wallet.json and never printed.
"""
import json, time, urllib.request, subprocess, sys, os, statistics

ROOT = "/home/hatch/workspace/dorahacks/reactive-omni/gaphunter"
BASE_URLS = ["https://sepolia.base.org", "https://base-sepolia.drpc.org"]
LASNA = "https://lasna-rpc.rnk.dev"
SEPOLIA = "https://api.zan.top/public/eth-sepolia"
FAUCET = "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"
WALLET = "0xdb75249615a23133fD10b8e96B9220EF1B950B5d"
RSC = "0x33BB79402a0802bE06D8b9F2b6171e80e54B3222"
EXEC = "0x986249121a4453294A68f6c7Cbc250Db6d30bF63"
GTA = "0x2250E6CAd8e9233eeb8f97434fA8aD2Cde071B1b"
GTB = "0xD6a779b928d8F284C7A30347a8302e3E0579aA20"
PAIR_A = "0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3"
PAIR_B = "0x8e62F00356C75791570182bB1A412BC4129f387a"
SIG_SIGNAL = "0x971e555bdd0b3416d51acae08cb13c3bef39bc8342526a9880879bf1375d6c6a"
SIG_EXEC = "0xcbc28a3fde15a46119e8269891df047f8d565acbacef6df53b535b4c3eb7f6d7"
E18 = 10**18
TARGET_TOTAL = 200

PK = json.load(open("/home/hatch/workspace/dorahacks/reactive-omni/evm-wallet.json"))["privateKey"]
ENV = dict(os.environ, PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.environ["PATH"])

class HardStop(Exception):
    pass

def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)

def rpc(urls, method, params, tries=8):
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

def eth_call(urls, to, data, block="latest"):
    return rpc(urls, "eth_call", [{"to": to, "data": data}, block])

def native_balance(urls, who):
    return int(rpc(urls, "eth_getBalance", [who, "latest"]), 16)

def reserves(pair):
    out = eth_call(BASE_URLS, pair, "0x0902f1ac")
    d = out[2:]
    return int(d[0:64], 16), int(d[64:128], 16)

def balance(token, who):
    out = eth_call(BASE_URLS, token, "0x70a08231" + who[2:].lower().rjust(64, "0"))
    return int(out, 16)

def u256(urls, to, selector):
    return int(eth_call(urls, to, selector), 16)

def block_ts(n):
    b = rpc(BASE_URLS, "eth_getBlockByNumber", [hex(n), False])
    return int(b["timestamp"], 16)

def cast_send(to, sig, args, rpc_url="https://sepolia.base.org"):
    cmd = ["cast", "send", "--rpc-url", rpc_url, "--private-key", PK, "--json", to, sig] + args
    p = None
    for i in range(4):
        p = subprocess.run(cmd, capture_output=True, text=True, env=ENV, timeout=120)
        if p.returncode == 0:
            return json.loads(p.stdout)
        log("cast send retry", i, p.stderr.strip()[:140])
        time.sleep(3 * (i + 1))
    raise RuntimeError(f"cast send {sig} failed: {p.stderr[:200]}")

def cast_value(to, value_wei, rpc_url):
    cmd = ["cast", "send", "--rpc-url", rpc_url, "--private-key", PK, "--json",
           "--value", str(value_wei), to]
    p = None
    for i in range(4):
        p = subprocess.run(cmd, capture_output=True, text=True, env=ENV, timeout=120)
        if p.returncode == 0:
            return json.loads(p.stdout)
        log("cast value retry", i, p.stderr.strip()[:140])
        time.sleep(3 * (i + 1))
    raise RuntimeError(f"cast value transfer failed: {p.stderr[:200]}")

def amount_out(amount_in, r_in, r_out):
    f = amount_in * 997
    return (f * r_out) // (r_in * 1000 + f)

def simulate(ra, rb, whale_pool, token_in, size):
    (a0, a1), (b0, b1) = ra, rb
    if whale_pool == "A":
        if token_in == "GTB":
            out = amount_out(size, a1, a0); a0 -= out; a1 += size
        else:
            out = amount_out(size, a0, a1); a1 -= out; a0 += size
    else:
        if token_in == "GTB":
            out = amount_out(size, b1, b0); b0 -= out; b1 += size
        else:
            out = amount_out(size, b0, b1); b1 -= out; b0 += size
    pa, pb = a1 / a0, b1 / b0
    return int(abs(pa - pb) / min(pa, pb) * 10000), out

def plan_whale(ra, rb, target_buy):
    sell_pool = "B" if target_buy == "A" else "A"
    cands = []
    for size_tok in (100_000, 150_000, 200_000):
        size = size_tok * E18
        s, out = simulate(ra, rb, sell_pool, "GTB", size)
        cands.append((size_tok, sell_pool, "GTB", s, out))
        s2, out2 = simulate(ra, rb, target_buy, "GTA", size)
        cands.append((size_tok, target_buy, "GTA", s2, out2))
    def direction_ok(c):
        size_tok, pool, tok, s, out = c
        (a0, a1), (b0, b1) = ra, rb
        size = size_tok * E18
        if pool == "A":
            if tok == "GTB": a0 -= out; a1 += size
            else: a1 -= out; a0 += size
        else:
            if tok == "GTB": b0 -= out; b1 += size
            else: b1 -= out; b0 += size
        pa, pb = a1 / a0, b1 / b0
        return (pa < pb) if target_buy == "A" else (pb < pa)
    ok = [c for c in cands if direction_ok(c)]
    for c in ok:
        if c[3] >= 600:
            return c
    return max(ok, key=lambda c: c[3]) if ok else cands[0]

def find_signal(nonce, from_lasna_block):
    topic1 = "0x" + format(nonce, "064x")
    hi = int(rpc(LASNA, "eth_blockNumber", []), 16)
    logs = rpc(LASNA, "eth_getLogs", [{"address": RSC, "fromBlock": hex(max(0, from_lasna_block - 3)),
                                       "toBlock": hex(hi), "topics": [SIG_SIGNAL, topic1]}])
    if not logs:
        return None
    l = logs[0]
    d = l["data"][2:]
    w = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
    return {"tx": l["transactionHash"], "block": int(l["blockNumber"], 16),
            "poolBuy": hex(w[0]), "poolSell": hex(w[1]), "amountIn": w[2],
            "spreadBps": w[3], "estimatedProfit": w[4]}

def find_exec_log(nonce, from_block, to_block):
    topic1 = "0x" + format(nonce, "064x")
    hi = to_block
    while hi >= from_block:
        lo = max(from_block, hi - 119)
        try:
            logs = rpc(BASE_URLS, "eth_getLogs", [{"address": EXEC, "fromBlock": hex(lo),
                                                   "toBlock": hex(hi), "topics": [SIG_EXEC, topic1]}], tries=4)
        except Exception:
            logs = []
        if logs:
            l = logs[0]
            d = l["data"][2:]
            w = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
            return {"tx": l["transactionHash"], "block": int(l["blockNumber"], 16),
                    "amountIn": w[2], "amountOut": w[3], "profit": w[4]}
        hi = lo - 1
    return None

def scan_executor_txs(from_block, to_block, seen):
    found = []
    for n in range(from_block, to_block + 1):
        try:
            b = rpc(BASE_URLS, "eth_getBlockByNumber", [hex(n), True], tries=3)
        except Exception:
            continue
        if not b:
            continue
        for tx in b.get("transactions", []):
            if (tx.get("to") or "").lower() == EXEC.lower() and tx["hash"] not in seen:
                seen.add(tx["hash"])
                try:
                    r = rpc(BASE_URLS, "eth_getTransactionReceipt", [tx["hash"]], tries=3)
                    status = int(r["status"], 16) if r else None
                except Exception:
                    status = None
                found.append({"tx": tx["hash"], "block": n, "status": status, "input": tx.get("input", "")})
    return found

def revert_reason(txhash):
    try:
        p = subprocess.run(["cast", "run", txhash, "--rpc-url", "https://sepolia.base.org"],
                           capture_output=True, text=True, env=ENV, timeout=90)
        txt = (p.stdout + p.stderr)
        for marker in ("unprofitable", "cooldown", "stale nonce", "no inventory", "pair mismatch"):
            if marker in txt:
                return marker
        return "reverted (reason not decoded)"
    except Exception:
        return "reverted (reason lookup failed)"

# ---------- funds management ----------

def ensure_rsc_funds(run_no):
    """Top up the RSC's lREACT if low. Raises HardStop if truly exhausted."""
    rsc_bal = native_balance(LASNA, RSC)
    if rsc_bal >= 120_000_000_000_000_000:  # >= 0.12 lREACT
        return rsc_bal
    log(f"run {run_no}: RSC lREACT low ({rsc_bal / E18:.4f}); attempting top-up")
    wal_bal = native_balance(LASNA, WALLET)
    if wal_bal > 20_000_000_000_000_000:
        amt = wal_bal - 5_000_000_000_000_000
        cast_value(RSC, amt, LASNA)
        log(f"run {run_no}: topped RSC with {amt / E18:.4f} lREACT from wallet")
        time.sleep(4)
        return native_balance(LASNA, RSC)
    # wallet lREACT empty: try buying via the faucet contract with Sepolia ETH
    sep_bal = native_balance(SEPOLIA, WALLET)
    if sep_bal > 2_500_000_000_000_000:  # > 0.0025 ETH
        amt_eth = sep_bal - 1_000_000_000_000_000  # keep 0.001 for gas
        cast_value(FAUCET, amt_eth, SEPOLIA)
        log(f"run {run_no}: sent {amt_eth / E18:.5f} Sepolia ETH to lREACT faucet")
        deadline = time.time() + 240
        while time.time() < deadline:
            time.sleep(10)
            wal_bal = native_balance(LASNA, WALLET)
            if wal_bal > 20_000_000_000_000_000:
                break
        if wal_bal > 20_000_000_000_000_000:
            amt = wal_bal - 5_000_000_000_000_000
            cast_value(RSC, amt, LASNA)
            log(f"run {run_no}: faucet delivered; topped RSC with {amt / E18:.4f} lREACT")
            time.sleep(4)
            return native_balance(LASNA, RSC)
    rsc_bal = native_balance(LASNA, RSC)
    if rsc_bal < 30_000_000_000_000_000:
        raise HardStop(f"RSC lREACT exhausted (balance {rsc_bal / E18:.4f}); "
                       f"wallet lREACT and Sepolia ETH also insufficient")
    return rsc_bal

def ensure_executor_eth(run_no):
    exec_bal = native_balance(BASE_URLS, EXEC)
    if exec_bal >= 1_200_000_000_000_000:  # >= 0.0012 ETH
        return exec_bal
    wal_bal = native_balance(BASE_URLS, WALLET)
    if wal_bal > 4_000_000_000_000_000:
        cast_value(EXEC, 2_000_000_000_000_000, "https://sepolia.base.org")
        log(f"run {run_no}: topped executor with 0.002 ETH")
        time.sleep(4)
        return native_balance(BASE_URLS, EXEC)
    raise HardStop(f"executor callback ETH low ({exec_bal / E18:.6f}) and wallet "
                   f"Base Sepolia ETH insufficient ({wal_bal / E18:.6f})")

# ---------- stats / checkpointing ----------

def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)

def compute_stats(runs):
    executed = [r for r in runs if r.get("outcome") == "executed"]
    refused = [r for r in runs if r.get("outcome") == "refused"]
    failed = [r for r in runs if r.get("outcome") not in ("executed", "refused")]
    lat = [r["latencySec"] for r in executed if r.get("latencySec") is not None]
    lat_blocks = [r["latencyBlocks"] for r in executed if r.get("latencyBlocks") is not None]
    total_profit = sum(r.get("profitGTB", 0.0) for r in executed)
    batch_profit = sum(r.get("profitGTB", 0.0) for r in executed if r["run"] >= 3)
    return {
        "totalRuns": len(runs),
        "executed": len(executed),
        "refused": len(refused),
        "failed": len(failed),
        "otherOutcomes": [{"run": r["run"], "outcome": r.get("outcome")} for r in failed],
        "latencySecP50": pct(lat, 50),
        "latencySecP95": pct(lat, 95),
        "latencySecMin": min(lat) if lat else None,
        "latencySecMax": max(lat) if lat else None,
        "latencyBlocksP50": pct(lat_blocks, 50),
        "latencyBlocksP95": pct(lat_blocks, 95),
        "latencyBlocksMedian": statistics.median(lat_blocks) if lat_blocks else None,
        "totalProfitGTB": round(total_profit, 6),
        "batchProfitGTB": round(batch_profit, 6),
        "originalProfitGTB": 8469.675457,
    }

def atomic_json_dump(obj, path):
    tmp = path + ".tmp"
    json.dump(obj, open(tmp, "w"), indent=2)
    os.replace(tmp, path)

def checkpoint(rec, partial_records, status="running"):
    runs_path = os.path.join(ROOT, "evidence", "runs.json")
    doc = json.load(open(runs_path))
    runs = [r for r in doc["runs"] if r["run"] != rec["run"]] + [rec]
    runs.sort(key=lambda r: r["run"])
    doc["runs"] = runs
    doc["stats"] = compute_stats(runs)
    doc["generatedFrom"] = ("Live runs on Base Sepolia (84532) + Reactive Lasna (5318007). "
                            "Runs 1-2: 2026-11-24 (see README Evidence). Runs 3-20: 2026-11-25 batch. "
                            "Runs 21+: 2026-11-25 extension batch toward 200 total runs.")
    atomic_json_dump(doc, runs_path)
    atomic_json_dump(partial_records, os.path.join(ROOT, "evidence", "runs_partial.json"))
    try:
        rsc_bal = native_balance(LASNA, RSC) / E18
        wal_lr = native_balance(LASNA, WALLET) / E18
        exec_eth = native_balance(BASE_URLS, EXEC) / E18
        wal_eth = native_balance(BASE_URLS, WALLET) / E18
    except Exception:
        rsc_bal = wal_lr = exec_eth = wal_eth = float("nan")
    lines = [
        f"target_total: {TARGET_TOTAL}",
        f"completed_total: {len(runs)}",
        f"last_run: {rec['run']}",
        f"last_outcome: {rec.get('outcome')}",
        f"last_profit_gtb: {rec.get('profitGTB')}",
        f"total_profit_gtb: {doc['stats']['totalProfitGTB']}",
        f"rsc_lreact: {rsc_bal:.6f}",
        f"wallet_lreact: {wal_lr:.6f}",
        f"executor_eth: {exec_eth:.6f}",
        f"wallet_base_sepolia_eth: {wal_eth:.6f}",
        f"status: {status}",
        f"updated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
    ]
    ppath = os.path.join(ROOT, "evidence", "batch200_progress.txt")
    tmp = ppath + ".tmp"
    open(tmp, "w").write("\n".join(lines) + "\n")
    os.replace(tmp, ppath)

# ---------- run execution ----------

SEL_LASTEXEC = SEL_NONCE = SEL_LASTARB = None

def selectors():
    global SEL_LASTEXEC, SEL_NONCE, SEL_LASTARB
    def sig(s):
        p = subprocess.run(["cast", "sig", s], capture_output=True, text=True, env=ENV)
        return p.stdout.strip()
    SEL_LASTEXEC = sig("lastExecAt()")
    SEL_NONCE = sig("nonce()")
    SEL_LASTARB = sig("lastArbBlock()")

def do_run(run_no, target_buy, rec):
    last_exec = u256(BASE_URLS, EXEC, SEL_LASTEXEC)
    wait = last_exec + 62 - time.time()
    if wait > 0:
        log(f"run {run_no}: pacing wait {wait:.0f}s (executor cooldown)")
        time.sleep(wait)
    while True:
        last_arb_blk = u256(LASNA, RSC, SEL_LASTARB)
        cur_lasna = int(rpc(LASNA, "eth_blockNumber", []), 16)
        if cur_lasna >= last_arb_blk + 21:
            break
        time.sleep(3)

    ra = reserves(PAIR_A); rb = reserves(PAIR_B)
    size_tok, whale_pool, token_in, spread_sim, out_sim = plan_whale(ra, rb, target_buy)
    size = size_tok * E18
    whale_pair = PAIR_A if whale_pool == "A" else PAIR_B
    token_addr = GTB if token_in == "GTB" else GTA
    rec.update({"whalePool": whale_pool, "whaleTokenIn": token_in,
                "whaleAmountIn": size_tok, "plannedSpreadBps": spread_sim})

    gtb_before = balance(GTB, EXEC)
    nonce_before = u256(LASNA, RSC, SEL_NONCE)
    lasna_before = int(rpc(LASNA, "eth_blockNumber", []), 16)
    rec["gtbBefore"] = gtb_before / E18
    rec["expectedNonce"] = nonce_before + 1

    cast_send(token_addr, "transfer(address,uint256)", [whale_pair, str(size)])
    r_now = reserves(whale_pair)
    if token_in == "GTB":
        out_amt = amount_out(size, r_now[1], r_now[0]); args = [str(out_amt), "0", WALLET, "0x"]
    else:
        out_amt = amount_out(size, r_now[0], r_now[1]); args = ["0", str(out_amt), WALLET, "0x"]
    rcpt = cast_send(whale_pair, "swap(uint256,uint256,address,bytes)", args)
    whale_tx = rcpt["transactionHash"]
    whale_block = int(rcpt["blockNumber"], 16) if isinstance(rcpt.get("blockNumber"), str) else rcpt["blockNumber"]
    origin_ts = block_ts(whale_block)
    rec.update({"whaleTx": whale_tx, "whaleBlock": whale_block, "originTs": origin_ts,
                "whaleAmountOut": out_amt / E18})
    log(f"run {run_no}: whale {token_in} {size_tok} into pool {whale_pool} tx {whale_tx[:14]}.. block {whale_block}")

    signal = None
    deadline = time.time() + 45
    while time.time() < deadline:
        try:
            n = u256(LASNA, RSC, SEL_NONCE)
            if n > nonce_before:
                signal = find_signal(nonce_before + 1, lasna_before)
                if signal:
                    break
        except Exception as e:
            log(f"run {run_no}: signal poll hiccup: {str(e)[:100]}")
        time.sleep(2)
    if not signal:
        rec["outcome"] = "no-signal"
        rec["gtbAfter"] = balance(GTB, EXEC) / E18
        rec["profitGTB"] = 0.0
        log(f"run {run_no}: NO SIGNAL")
        return rec
    rec.update({"reactTx": signal["tx"], "reactLasnaBlock": signal["block"],
                "signalSpreadBps": signal["spreadBps"], "signalAmountInGTB": signal["amountIn"] / E18,
                "signalPoolBuy": signal["poolBuy"], "signalPoolSell": signal["poolSell"]})
    log(f"run {run_no}: signalled nonce {nonce_before + 1} spread {signal['spreadBps']}bps react {signal['tx'][:14]}..")

    callback = None; refused = None
    deadline = time.time() + 100
    wait_start = time.time()
    scanned = False
    while time.time() < deadline:
        try:
            cur = int(rpc(BASE_URLS, "eth_blockNumber", []), 16)
            ex = find_exec_log(nonce_before + 1, whale_block, cur)
            if ex:
                callback = ex
                break
            if not scanned and time.time() - wait_start > 40:
                scanned = True
                seen = set()
                for t in scan_executor_txs(max(whale_block + 1, cur - 150), cur, seen):
                    if t["status"] == 0:
                        refused = t
                        break
                if refused:
                    break
        except Exception as e:
            log(f"run {run_no}: callback poll hiccup: {str(e)[:100]}")
        time.sleep(3)
    time.sleep(6)
    gtb_after = balance(GTB, EXEC)
    rec["gtbAfter"] = gtb_after / E18
    if callback:
        cb_ts = block_ts(callback["block"])
        rec.update({"outcome": "executed", "callbackTx": callback["tx"],
                    "callbackBlock": callback["block"], "callbackTs": cb_ts,
                    "latencySec": cb_ts - origin_ts, "latencyBlocks": callback["block"] - whale_block,
                    "profitGTB": callback["profit"] / E18,
                    "profitRaw": str(callback["profit"]),
                    "balanceDeltaGTB": (gtb_after - gtb_before) / E18})
        log(f"run {run_no}: EXECUTED profit {callback['profit'] / E18:.4f} GTB latency {cb_ts - origin_ts}s")
    elif refused:
        rec.update({"outcome": "refused", "callbackTx": refused["tx"],
                    "callbackBlock": refused["block"], "callbackTs": block_ts(refused["block"]),
                    "refusalReason": revert_reason(refused["tx"]), "profitGTB": 0.0,
                    "balanceDeltaGTB": (gtb_after - gtb_before) / E18})
        log(f"run {run_no}: REFUSED ({rec['refusalReason']})")
    else:
        rec.update({"outcome": "no-callback", "profitGTB": 0.0,
                    "balanceDeltaGTB": (gtb_after - gtb_before) / E18})
        log(f"run {run_no}: NO CALLBACK within timeout")
    return rec

def main():
    runs_file = os.path.join(ROOT, "evidence", "runs_partial.json")
    records = []
    if os.path.exists(runs_file):
        records = json.load(open(runs_file))
    done = {r["run"] for r in records if r.get("outcome") in ("executed", "refused")}
    log("resuming; already recorded:", sorted({r['run'] for r in records}))

    if balance(GTB, WALLET) < 500_000 * E18:
        cast_send(GTB, "mint(address,uint256)", [WALLET, str(3_000_000 * E18)])
        log("minted 3,000,000 GTB to wallet")
    if balance(GTA, WALLET) < 500_000 * E18:
        cast_send(GTA, "mint(address,uint256)", [WALLET, str(2_000_000 * E18)])
        log("minted 2,000,000 GTA to wallet")

    status = "running"
    for run_no in range(21, TARGET_TOTAL + 1):
        if run_no in done:
            continue
        target_buy = "A" if run_no % 2 == 1 else "B"
        rec = {"run": run_no, "targetBuyPool": target_buy, "date": "2026-11-25"}
        try:
            rec["rscLreactBefore"] = ensure_rsc_funds(run_no) / E18
            rec["execEthBefore"] = ensure_executor_eth(run_no) / E18
            rec = do_run(run_no, target_buy, rec)
        except HardStop as e:
            status = f"hard-stop: {e}"
            log(f"HARD STOP before run {run_no}: {e}")
            # write progress with the last completed record
            prev = records[-1] if records else {"run": 20, "outcome": "executed", "profitGTB": 0}
            checkpoint(prev, records, status=status)
            log("BATCH STOPPED (funds)")
            return
        except Exception as e:
            rec["outcome"] = "error"
            rec["error"] = str(e)[:300]
            log(f"run {run_no}: ERROR {str(e)[:200]}")
        try:
            rec["rscLreactAfter"] = native_balance(LASNA, RSC) / E18
            rec["execEthAfter"] = native_balance(BASE_URLS, EXEC) / E18
        except Exception:
            pass
        records = [r for r in records if r["run"] != run_no] + [rec]
        records.sort(key=lambda r: r["run"])
        checkpoint(rec, records, status="running")
        log(f"run {run_no} recorded: outcome={rec.get('outcome')} profit={rec.get('profitGTB')}")

    log("BATCH COMPLETE (200 total runs)")

if __name__ == "__main__":
    selectors()
    main()
