#!/usr/bin/env bash
# verify-deployment.sh — prove the deployed GapHunter contracts are exactly
# the contracts in this repository, without trusting any explorer.
#
# For each contract it:
#   1. recompiles the project (forge build),
#   2. fetches the deployed runtime bytecode with `cast code`,
#   3. patches the locally compiled bytecode's immutable-variable regions
#      with the values found on-chain (immutables are baked into runtime
#      code at construction time, so the compiler artifact carries zeros
#      in those slots),
#   4. compares the two byte-for-byte, CBOR metadata hash included.
#
# A MATCH means the on-chain contract is a byte-exact instance of the
# source in src/ built with the settings in foundry.toml.
#
# Requires: forge, cast, python3, and network access to the two RPCs.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

BASE_RPC="${BASE_RPC:-https://sepolia.base.org}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev}"

echo "== forge build =="
forge build --quiet

check() { # $1 contract name, $2 address, $3 rpc
  python3 - "$1" "$2" "$3" <<'PY'
import json, subprocess, sys

name, addr, rpc = sys.argv[1], sys.argv[2], sys.argv[3]
art = json.load(open(f"out/{name}.sol/{name}.json"))
dep = art["deployedBytecode"]
local = dep["object"].lower().removeprefix("0x")
refs = dep.get("immutableReferences", {})

out = subprocess.run(["cast", "code", addr, "--rpc-url", rpc],
                     capture_output=True, text=True)
if out.returncode != 0:
    print(f"{name}: could not fetch on-chain code: {out.stderr.strip()}")
    sys.exit(2)
onchain = out.stdout.strip().lower().removeprefix("0x")

lb, ob = bytearray(bytes.fromhex(local)), bytes.fromhex(onchain)
if len(lb) != len(ob):
    print(f"{name}: LENGTH MISMATCH local={len(lb)} on-chain={len(ob)}")
    sys.exit(1)
for spans in refs.values():
    for sp in spans:
        s, l = sp["start"], sp["length"]
        lb[s:s + l] = ob[s:s + l]

if bytes(lb) == ob:
    print(f"{name} @ {addr}: MATCH "
          f"({len(ob)} bytes, byte-for-byte incl. metadata hash)")
else:
    diff = next(i for i in range(len(ob)) if lb[i] != ob[i])
    print(f"{name}: MISMATCH at byte {diff}")
    sys.exit(1)
PY
}

echo "== bytecode comparison =="
check GapHunterExecutor 0x986249121a4453294A68f6c7Cbc250Db6d30bF63 "$BASE_RPC"
check GapHunterReactive 0x33BB79402a0802bE06D8b9F2b6171e80e54B3222 "$LASNA_RPC"

echo "== Sourcify status =="
for pair in "84532 0x986249121a4453294A68f6c7Cbc250Db6d30bF63" \
            "5318007 0x33BB79402a0802bE06D8b9F2b6171e80e54B3222"; do
  set -- $pair
  status=$(curl -s --max-time 20 "https://sourcify.dev/server/v2/contract/$1/$2" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('match'))" 2>/dev/null || echo "unreachable")
  echo "chain $1 $2: $status"
done

echo "OK: deployments verified."
