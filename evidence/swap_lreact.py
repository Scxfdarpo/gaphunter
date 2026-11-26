#!/usr/bin/env python3
"""Swap most of the project wallet's Ethereum Sepolia ETH for lREACT.

Sends a plain ETH transfer to the lREACT exchange contract
0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 (1 ETH -> ~100 lREACT,
credited to the wallet's Lasna balance). Keeps ~0.001 ETH in reserve
plus gas (60000 @ 2 gwei). Private key is read from evm-wallet.json
and never printed.
"""
import json
import sys
import time
import urllib.request

from eth_account import Account

SEPOLIA_RPC = "https://api.zan.top/public/eth-sepolia"
LASNA_RPC = "https://lasna-rpc.rnk.dev"
WALLET_JSON = "/home/hatch/workspace/dorahacks/reactive-omni/evm-wallet.json"
FAUCET = "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"
RESERVE_WEI = 1_000_000_000_000_000      # 0.001 ETH kept in wallet
GAS_LIMIT = 60_000
GAS_PRICE_WEI = 2_000_000_000            # 2 gwei


def rpc(url, method, params):
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    ).encode()
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.load(resp)
    if "error" in out:
        raise RuntimeError(f"RPC {method} failed: {out['error']}")
    return out["result"]


def main():
    with open(WALLET_JSON) as f:
        key = json.load(f)["privateKey"]
    acct = Account.from_key(key)
    addr = acct.address

    bal = int(rpc(SEPOLIA_RPC, "eth_getBalance", [addr, "latest"]), 16)
    print(f"wallet {addr}")
    print(f"sepolia ETH balance: {bal / 1e18:.6f}")
    gas_cost = GAS_LIMIT * GAS_PRICE_WEI
    amount = bal - RESERVE_WEI - gas_cost
    if amount <= 0:
        print("NOT ENOUGH: balance covers reserve+gas only, nothing to swap")
        return 1
    print(f"swapping {amount / 1e18:.6f} ETH -> lREACT "
          f"(reserve 0.001 ETH, gas {gas_cost / 1e18:.6f} ETH)")

    nonce = int(rpc(SEPOLIA_RPC, "eth_getTransactionCount",
                    [addr, "pending"]), 16)
    tx = {
        "to": FAUCET,
        "value": amount,
        "gas": GAS_LIMIT,
        "gasPrice": GAS_PRICE_WEI,
        "nonce": nonce,
        "chainId": 11155111,
    }
    signed = acct.sign_transaction(tx)
    raw = "0x" + signed.raw_transaction.hex()
    tx_hash = rpc(SEPOLIA_RPC, "eth_sendRawTransaction", [raw])
    print(f"swap tx sent: {tx_hash}")

    for i in range(30):
        time.sleep(10)
        rcpt = rpc(SEPOLIA_RPC, "eth_getTransactionReceipt", [tx_hash])
        if rcpt:
            print(f"confirmed in block {int(rcpt['blockNumber'], 16)} "
                  f"status={int(rcpt['status'], 16)}")
            break
    else:
        print("receipt not seen after 5 min; check tx hash manually")
        return 2

    lasna_before = int(rpc(LASNA_RPC, "eth_getBalance", [addr, "latest"]), 16)
    print(f"wallet Lasna lREACT now: {lasna_before / 1e18:.6f} "
          f"(credit may take a few minutes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
