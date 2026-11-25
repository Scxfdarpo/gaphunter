#!/usr/bin/env python3
"""Polling-keeper baseline: poll both pairs' getReserves every ~2s and log
the spot spread. A polling keeper would 'detect' a gap at the first sample
where spreadBps >= 150 after a whale swap. Read-only; appends JSONL."""
import json, time, urllib.request, sys

BASE_URLS = ["https://sepolia.base.org", "https://base-sepolia.drpc.org"]
PAIR_A = "0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3"
PAIR_B = "0x8e62F00356C75791570182bB1A412BC4129f387a"
GET_RESERVES = "0x0902f1ac"
OUT = "/home/hatch/workspace/dorahacks/reactive-omni/gaphunter/evidence/poll.jsonl"

def call(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)

def sample(idx):
    batch = [
        {"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
        {"jsonrpc": "2.0", "id": 2, "method": "eth_call", "params": [{"to": PAIR_A, "data": GET_RESERVES}, "latest"]},
        {"jsonrpc": "2.0", "id": 3, "method": "eth_call", "params": [{"to": PAIR_B, "data": GET_RESERVES}, "latest"]},
    ]
    out = call(BASE_URLS[idx % len(BASE_URLS)], batch)
    by_id = {o["id"]: o for o in out}
    if any("error" in o for o in by_id.values()):
        raise RuntimeError("rpc error in batch")
    block = int(by_id[1]["result"], 16)
    def res(o):
        d = o["result"][2:]
        return int(d[0:64], 16), int(d[64:128], 16)
    ra0, ra1 = res(by_id[2]); rb0, rb1 = res(by_id[3])
    pa = ra1 / ra0; pb = rb1 / rb0
    cheap = min(pa, pb)
    spread_bps = int(abs(pa - pb) / cheap * 10000)
    return {"t": time.time(), "block": block, "rA0": ra0, "rA1": ra1,
            "rB0": rb0, "rB1": rb1, "spreadBps": spread_bps}

def main():
    idx = 0
    with open(OUT, "a") as f:
        while True:
            t0 = time.time()
            try:
                s = sample(idx)
                f.write(json.dumps(s) + "\n"); f.flush()
            except Exception as e:
                f.write(json.dumps({"t": time.time(), "error": str(e)[:120]}) + "\n"); f.flush()
                idx += 1
            dt = time.time() - t0
            if dt < 2.0:
                time.sleep(2.0 - dt)

if __name__ == "__main__":
    main()
