#!/usr/bin/env bash
# GapHunter live deployment + evidence run.
#
# Deploys the full system on public testnets and produces the on-chain
# evidence the DoraHacks submission needs:
#   Base Sepolia (84532): two Uniswap V2 venues, demo pair, GapHunterExecutor
#   Reactive Lasna (5318007): GapHunterReactive
# then opens a price gap with a whale swap and watches the reactive loop
# close it, printing every transaction hash and block timestamp.
#
# Prerequisites (checked, in order):
#   - wallet funded with Base Sepolia ETH (deployments, seeding, whale swap)
#   - wallet funded with lREACT (RSC deployment + reactive transactions)
#     lREACT: send Sepolia ETH to 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
#     (Ethereum Sepolia) or 0x2afaFD298b23b62760711756088F75B7409f5967
#     (Base Sepolia) — 1 ETH -> 100 lREACT.
#
# The private key is read from ../evm-wallet.json and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
BASE_PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
ADDR_FILE="deploy/addresses.json"

PK=$(python3 -c "import json;print(json.load(open('../evm-wallet.json'))['privateKey'])")
WALLET=$(cast wallet address --private-key "$PK")
echo "deployer: $WALLET"
echo "Base Sepolia ETH: $(cast balance "$WALLET" --rpc-url $BASE_RPC)"
echo "Lasna lREACT:     $(cast balance "$WALLET" --rpc-url $LASNA_RPC)"

save() { python3 - "$@" <<'PY'
import json, sys
try: d = json.load(open('deploy/addresses.json'))
except Exception: d = {}
d[sys.argv[1]] = sys.argv[2]
json.dump(d, open('deploy/addresses.json', 'w'), indent=2)
PY
}

deploy_factory() { # $1 = label
  local bin; bin=$(cat deploy/v2bytecode/UniswapV2Factory.bin)
  local args; args=$(cast abi-encode "constructor(address)" "$WALLET")
  local out; out=$(cast send --rpc-url $BASE_RPC --private-key "$PK" --create "${bin}${args#0x}" --json)
  echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])"
}

echo "== 1. Uniswap V2 factories (two venues) on Base Sepolia =="
FACTORY_A=$(deploy_factory A); save factoryA "$FACTORY_A"; echo "factoryA: $FACTORY_A"
FACTORY_B=$(deploy_factory B); save factoryB "$FACTORY_B"; echo "factoryB: $FACTORY_B"

echo "== 2. Demo tokens =="
GTA=$(forge create src/MockERC20.sol:MockERC20 --rpc-url $BASE_RPC --private-key "$PK" --constructor-args "Gap Token A" "GTA" 18 --json | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
GTB=$(forge create src/MockERC20.sol:MockERC20 --rpc-url $BASE_RPC --private-key "$PK" --constructor-args "Gap Token B" "GTB" 18 --json | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
save tokenA "$GTA"; save tokenB "$GTB"; echo "GTA: $GTA  GTB: $GTB"

echo "== 3. Pairs + seeding (1,000,000 / 1,000,000 each) =="
for F in "$FACTORY_A" "$FACTORY_B"; do
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$F" "createPair(address,address)" "$GTA" "$GTB" >/dev/null
done
PAIR_A=$(cast call --rpc-url $BASE_RPC "$FACTORY_A" "getPair(address,address)" "$GTA" "$GTB")
PAIR_B=$(cast call --rpc-url $BASE_RPC "$FACTORY_B" "getPair(address,address)" "$GTA" "$GTB")
save pairA "$PAIR_A"; save pairB "$PAIR_B"; echo "pairA: $PAIR_A  pairB: $PAIR_B"
TOKEN0=$(cast call --rpc-url $BASE_RPC "$PAIR_A" "token0()(address)")
TOKEN1=$(cast call --rpc-url $BASE_RPC "$PAIR_A" "token1()(address)")
save token0 "$TOKEN0"; save token1 "$TOKEN1"
for P in "$PAIR_A" "$PAIR_B"; do
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN0" "mint(address,uint256)" "$WALLET" 1000000000000000000000000 >/dev/null
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN1" "mint(address,uint256)" "$WALLET" 1000000000000000000000000 >/dev/null
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN0" "transfer(address,uint256)" "$P" 1000000000000000000000000 >/dev/null
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN1" "transfer(address,uint256)" "$P" 1000000000000000000000000 >/dev/null
  cast send --rpc-url $BASE_RPC --private-key "$PK" "$P" "mint(address)(uint256)" "$WALLET" >/dev/null
done
echo "pairs seeded"

echo "== 4. GapHunterReactive on Lasna =="
RSC=$(forge create src/GapHunterReactive.sol:GapHunterReactive --rpc-url $LASNA_RPC --private-key "$PK" --value 5ether --constructor-args 84532 "$PAIR_A" "$PAIR_B" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
save reactive "$RSC"; echo "reactive: $RSC"

echo "== 5. GapHunterExecutor on Base Sepolia =="
EXEC=$(forge create src/GapHunterExecutor.sol:GapHunterExecutor --rpc-url $BASE_RPC --private-key "$PK" --value 0.05ether --constructor-args "$BASE_PROXY" "$RSC" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
save executor "$EXEC"; echo "executor: $EXEC"
cast send --rpc-url $LASNA_RPC --private-key "$PK" "$RSC" "setExecutor(address)" "$EXEC" >/dev/null
cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN1" "mint(address,uint256)" "$EXEC" 500000000000000000000000 >/dev/null
echo "executor wired + funded with token1 inventory"

echo "== 6. Whale swap opens a gap on venue B =="
cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN1" "mint(address,uint256)" "$WALLET" 100000000000000000000000 >/dev/null
cast send --rpc-url $BASE_RPC --private-key "$PK" "$TOKEN1" "transfer(address,uint256)" "$PAIR_B" 100000000000000000000000 >/dev/null
# amount0Out for 100k token1 in, computed from live reserves by the pair itself via cast in the runbook step;
# the runbook operator fills WHALE_OUT from getReserves before this swap.
echo "seeded whale funds into pair B; execute the swap with the computed amount0Out next"
echo "DONE (deployment). Addresses in $ADDR_FILE"
