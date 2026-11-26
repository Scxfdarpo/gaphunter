#!/usr/bin/env python3
"""Run 3 live full-loop arbitrage runs on the Unichain Sepolia leg of GapHunter.

Whale swap (token1 in) on a pair -> Sync delivered to GapHunterReactive #2 on
Lasna -> callback -> GapHunterExecutor executes on Unichain Sepolia.
Each run is verified via the executor's ArbExecuted log and token1 balance
delta. Records are written incrementally to evidence/unichain-runs.json.
"""
import json, subprocess, sys, time, os

os.environ["PATH"] = os.path.expanduser("~/.foundry/bin") + ":" + os.environ["PATH"]
ROOT = os.path.expanduser("~/workspace/dorahacks/reactive-omni/gaphunter")
UNI = "https://sepolia.unichain.org"
LASNA = "https://lasna-rpc.rnk.dev"
PK = json.load(open(os.path.expanduser("~/workspace/dorahacks/reactive-omni/evm-wallet.json")))["privateKey"]
WALLET = "0xdb75249615a23133fD10b8e96B9220EF1B950B5d"

A = json.load(open(f"{ROOT}/deploy/addresses-unichain.json"))
PAIR = {"A": A["pairA"], "B": A["pairB"]}
TOKEN0, TOKEN1 = A["token0"], A["token1"]  # token0 = GTB, token1 = GTA on Unichain
RSC, EXEC = A["reactive"], A["executor"]
OUT = f"{ROOT}/evidence/unichain-runs.json"
E18 = 10**18


def cast(*args, rpc, check=True):
    # Public RPCs are load-balanced; a node can lag behind the one that
    # accepted a tx ("block not found"). Retry reads before giving up.
    last = ""
    for i in range(8):
        r = subprocess.run(["cast", *args, "--rpc-url", rpc], capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            return r.stdout.strip()
        last = r.stderr.strip()[:300]
        if not check:
            return r.stdout.strip()
        time.sleep(3)
    raise RuntimeError(f"cast {args} failed: {last}")


def call(addr, sig, rpc, *args):
    return cast("call", addr, sig, *args, rpc=rpc)


def send(addr, sig, rpc, *args, value=None):
    """cast send with retries for the public RPCs' stale-nonce rejections."""
    last = ""
    for i in range(8):
        cmd = ["cast", "send", addr, sig, *args, "--rpc-url", rpc, "--private-key", PK, "--json"]
        if value:
            cmd += ["--value", value]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if r.returncode == 0:
            return json.loads(r.stdout)
        last = r.stderr.strip()[:300]
        print(f"    send retry {i+1}: {last}", flush=True)
        time.sleep(3)
    raise RuntimeError(f"send {sig} failed permanently: {last}")


def block_ts(block, rpc):
    out = cast("block", str(block), "--field", "timestamp", rpc=rpc)
    return int(out)


def block_num(rpc):
    return int(cast("block-number", rpc=rpc))


def logs(addr, sig, from_block, rpc):
    out = cast("logs", "--address", addr, "--from-block", str(from_block), "--json", sig, rpc=rpc, check=False)
    try:
        return json.loads(out) if out else []
    except Exception:
        return []


def amount_out(amount_in, reserve_in, reserve_out):
    return (amount_in * 997 * reserve_out) // (reserve_in * 1000 + amount_in * 997)


def reserves(pair):
    out = call(pair, "getReserves()(uint112,uint112,uint32)", UNI)
    parts = [int(x.split()[0]) for x in out.splitlines()]
    return parts[0], parts[1]


def exec_token1():
    return int(call(TOKEN1, "balanceOf(address)(uint256)", UNI, EXEC).split()[0])


def exec_count():
    return int(call(EXEC, "arbsExecuted()(uint256)", UNI).split()[0])


def main():
    doc = {
        "project": "GapHunter — cross-chain second leg (Unichain Sepolia)",
        "generatedFrom": "live runs driven by evidence/unichain_driver.py",
        "chain": {"origin": "Unichain Sepolia (1301)", "reactive": "Reactive Lasna (5318007)"},
        "token1Symbol": "GTA",
        "token0Symbol": "GTB",
        "contracts": {
            "factoryA": A["factoryA"], "factoryB": A["factoryB"],
            "tokenA": A["tokenA"], "tokenB": A["tokenB"],
            "pairA": A["pairA"], "pairB": A["pairB"],
            "reactive": RSC, "executor": EXEC,
            "callbackProxy": A["callbackProxy"],
        },
        "runs": [],
    }
    if os.path.exists(OUT):
        doc = json.load(open(OUT))
    done = len(doc["runs"])
    TARGET = 20
    # Runs 1-3 went B, A, B; keep alternating (odd run -> B, even run -> A).
    plan = [("A" if n % 2 == 0 else "B") for n in range(done + 1, TARGET + 1)]
    print(f"starting: {done} runs already recorded, plan {plan}", flush=True)

    for pool_label in plan:
        n = len(doc["runs"]) + 1
        pair = PAIR[pool_label]
        # Respect the executor's 60 s timestamp cooldown across driver restarts.
        last_exec = int(call(EXEC, "lastExecAt()(uint256)", UNI).split()[0])
        wait = (last_exec + 75) - int(time.time())
        if last_exec > 0 and wait > 0:
            print(f"  waiting {wait} s for executor cooldown", flush=True)
            time.sleep(wait)
        before_bal, before_cnt = exec_token1(), exec_count()
        lasna_start = block_num(LASNA)
        print(f"run {n}: whale 100,000 token1 (GTA) into pair {pool_label} {pair}", flush=True)
        send(TOKEN1, "mint(address,uint256)", UNI, WALLET, str(100_000 * E18))
        send(TOKEN1, "transfer(address,uint256)", UNI, pair, str(100_000 * E18))
        r0, r1 = reserves(pair)
        out_amt = amount_out(100_000 * E18, r1, r0)
        # reserves() was read AFTER the transfer landed? No: transfer does not
        # change reserves until swap; but the balance is already in, and V2
        # swap computes from reserves + balance. amountOut from stored
        # reserves is what the pair will pay for amount0Out <= that value.
        receipt = send(pair, "swap(uint256,uint256,address,bytes)", UNI,
                       str(out_amt), "0", WALLET, "0x")
        whale_tx = receipt["transactionHash"]
        whale_block = int(receipt["blockNumber"], 16)
        whale_ts = block_ts(whale_block, UNI)
        print(f"  whale tx {whale_tx} block {whale_block} ts {whale_ts}", flush=True)

        # Wait for the reactive loop to execute on Unichain.
        deadline = time.time() + 300
        new_cnt = before_cnt
        while time.time() < deadline:
            time.sleep(3)
            try:
                new_cnt = exec_count()
            except Exception:
                continue
            if new_cnt > before_cnt:
                break
        if new_cnt <= before_cnt:
            print(f"  RUN {n}: NO EXECUTION within 300 s — recording as failed", flush=True)
            doc["runs"].append({
                "run": n, "date": time.strftime("%Y-%m-%d", time.gmtime()), "chain": "Unichain Sepolia (1301)",
                "whaleTx": whale_tx, "whalePool": pool_label, "whaleTokenIn": "GTA",
                "whaleAmountIn": 100000, "whaleBlock": whale_block, "whaleBlockTs": whale_ts,
                "originTx": whale_tx, "originBlock": whale_block, "originTs": whale_ts,
                "outcome": "not executed within 300 s",
            })
            json.dump(doc, open(OUT, "w"), indent=2)
            continue

        # Locate the ArbExecuted log (callback tx) and ArbSignalled (react tx).
        cb = [l for l in logs(EXEC, "ArbExecuted(uint256,address,address,uint256,uint256,uint256)", whale_block, UNI)
              if int(l["blockNumber"], 16) >= whale_block]
        cb.sort(key=lambda l: int(l["blockNumber"], 16))
        cb_log = cb[-1]
        cb_tx = cb_log["transactionHash"]
        cb_block = int(cb_log["blockNumber"], 16)
        cb_ts = block_ts(cb_block, UNI)
        nonce = int(cb_log["topics"][1], 16)

        react_tx, react_block = None, None
        for l in logs(RSC, "ArbSignalled(uint256,address,address,uint256,uint256,uint256)", lasna_start, LASNA):
            if int(l["topics"][1], 16) == nonce:
                react_tx, react_block = l["transactionHash"], int(l["blockNumber"], 16)
                break

        after_bal = exec_token1()
        profit_raw = after_bal - before_bal
        rec = {
            "run": n, "date": time.strftime("%Y-%m-%d", time.gmtime()), "chain": "Unichain Sepolia (1301)",
            "whaleTx": whale_tx, "whalePool": pool_label, "whaleTokenIn": "GTA",
            "whaleAmountIn": 100000, "whaleBlock": whale_block, "whaleBlockTs": whale_ts,
            "originTx": whale_tx, "originBlock": whale_block, "originTs": whale_ts,
            "reactTx": react_tx, "reactLasnaBlock": react_block,
            "callbackTx": cb_tx, "callbackBlock": cb_block, "callbackTs": cb_ts,
            "latencySec": cb_ts - whale_ts, "latencyBlocks": cb_block - whale_block,
            "gtbBefore": before_bal / E18, "gtbAfter": after_bal / E18,
            "profitGTB": profit_raw / E18, "profitRaw": str(profit_raw),
            "profitTokenNote": "amounts are in token1, which on Unichain Sepolia is GTA",
            "arbNonce": nonce, "outcome": "executed",
        }
        doc["runs"].append(rec)
        json.dump(doc, open(OUT, "w"), indent=2)
        print(f"  executed: nonce {nonce} react {react_tx} callback {cb_tx} "
              f"latency {rec['latencySec']} s / {rec['latencyBlocks']} blocks profit {rec['profitGTB']} GTA", flush=True)

        # Executor cooldown is 60 s (timestamp-based); wait it out.
        wait = (cb_ts + 75) - int(time.time())
        if wait > 0 and len(doc["runs"]) < TARGET:
            print(f"  cooling down {wait} s", flush=True)
            time.sleep(wait)

    doc["stats"] = {
        "runs": len(doc["runs"]),
        "executed": sum(1 for r in doc["runs"] if r["outcome"] == "executed"),
        "totalProfitToken1": sum(r.get("profitGTB", 0) for r in doc["runs"]),
    }
    json.dump(doc, open(OUT, "w"), indent=2)
    print("DONE", json.dumps(doc["stats"]), flush=True)


if __name__ == "__main__":
    main()
