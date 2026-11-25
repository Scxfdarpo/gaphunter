#!/usr/bin/env python3
"""GapHunter batch driver: 18 additional live full-loop runs (runs 3..20).

Per run: adaptive whale swap (alternating target buy pool, size escalates
100k -> 150k -> 200k only if needed to flip/create a >=600bps gap), then
waits for the Lasna ArbSignalled event and the Base Sepolia callback tx
to the executor, records outcome (executed / refused / no-signal),
executor GTB before/after, and enforces the executor's 60s cooldown
before the next whale. Writes evidence/runs_partial.json incrementally.
The private key is loaded from evm-wallet.json and never printed.
"""
import json, time, urllib.request, subprocess, sys, os

ROOT = "/home/hatch/workspace/dorahacks/reactive-omni/gaphunter"
BASE_URLS = ["https://sepolia.base.org", "https://base-sepolia.drpc.org"]
LASNA = "https://lasna-rpc.rnk.dev"
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

PK = json.load(open("/home/hatch/workspace/dorahacks/reactive-omni/evm-wallet.json"))["privateKey"]
ENV = dict(os.environ, PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.environ["PATH"])

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
    for i in range(4):
        p = subprocess.run(cmd, capture_output=True, text=True, env=ENV, timeout=120)
        if p.returncode == 0:
            return json.loads(p.stdout)
        log("cast send retry", i, p.stderr.strip()[:140])
        time.sleep(3 * (i + 1))
    raise RuntimeError(f"cast send {sig} failed: {p.stderr[:200]}")

def amount_out(amount_in, r_in, r_out):
    f = amount_in * 997
    return (f * r_out) // (r_in * 1000 + f)

def simulate(ra, rb, whale_pool, token_in, size):
    """Return (spread_bps_after, out_amount) if whale of `size` token_in goes into whale_pool."""
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
    """target_buy: pool the executor should BUY on (cheap). The other pool must end expensive."""
    sell_pool = "B" if target_buy == "A" else "A"
    cands = []
    for size_tok in (100_000, 150_000, 200_000):
        size = size_tok * E18
        # GTB into the sell pool raises its GTA price (makes it expensive)
        s, out = simulate(ra, rb, sell_pool, "GTB", size)
        pa = (rb if sell_pool == "B" else ra)
        cands.append((size_tok, sell_pool, "GTB", s, out))
        # GTA into the buy pool lowers its GTA price (makes it cheap)
        s2, out2 = simulate(ra, rb, target_buy, "GTA", size)
        cands.append((size_tok, target_buy, "GTA", s2, out2))
    # verify direction: after whale, target_buy must actually be the cheap pool
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
    """Search [from_block, to_block] for the ArbExecuted log of `nonce`,
    in <=120-block chunks walking backwards (public RPCs reject wide ranges)."""
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
    """Find txs to the executor in [from_block, to_block]; returns list of (txhash, block, status)."""
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

def main():
    runs_file = os.path.join(ROOT, "evidence", "runs_partial.json")
    records = []
    if os.path.exists(runs_file):
        records = json.load(open(runs_file))
        done = {r["run"] for r in records}
        log("resuming; already recorded:", sorted(done))
    else:
        done = set()

    # Top up whale ammunition (anyone-can-mint demo tokens).
    if balance(GTB, WALLET) < 500_000 * E18:
        cast_send(GTB, "mint(address,uint256)", [WALLET, str(3_000_000 * E18)])
        log("minted 3,000,000 GTB to wallet")
    if balance(GTA, WALLET) < 500_000 * E18:
        cast_send(GTA, "mint(address,uint256)", [WALLET, str(2_000_000 * E18)])
        log("minted 2,000,000 GTA to wallet")

    for run_no in range(3, 21):
        if run_no in done:
            continue
        target_buy = "A" if run_no % 2 == 1 else "B"
        rec = {"run": run_no, "targetBuyPool": target_buy}
        try:
            rec = do_run(run_no, target_buy, rec)
        except Exception as e:
            rec["outcome"] = "error"
            rec["error"] = str(e)[:300]
            log(f"run {run_no}: ERROR {str(e)[:200]}")
        records.append(rec)
        json.dump(records, open(runs_file, "w"), indent=2)
        log(f"run {run_no} recorded: outcome={rec.get('outcome')} profit={rec.get('profitGTB')}")

    log("BATCH COMPLETE")

SEL_LASTEXEC = None
SEL_LASTNONCE = None
SEL_NONCE = None
SEL_LASTARB = None

def selectors():
    global SEL_LASTEXEC, SEL_LASTNONCE, SEL_NONCE, SEL_LASTARB
    def sig(s):
        p = subprocess.run(["cast", "sig", s], capture_output=True, text=True, env=ENV)
        return p.stdout.strip()
    SEL_LASTEXEC = sig("lastExecAt()")
    SEL_LASTNONCE = sig("lastNonce()")
    SEL_NONCE = sig("nonce()")
    SEL_LASTARB = sig("lastArbBlock()")

def do_run(run_no, target_buy, rec):
    # --- pacing waits ---
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

    # --- whale swap: fund pair, then swap ---
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

    # --- wait for Lasna signal ---
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

    # --- wait for callback on Base ---
    # Primary signal: the ArbExecuted log (cheap, indexed). Only if 40s pass
    # with no execution do we scan recent blocks once for a reverted callback.
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
    time.sleep(6)  # settle
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

if __name__ == "__main__":
    selectors()
    main()
