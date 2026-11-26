#!/usr/bin/env bash
# GapHunter CROSS-CHAIN second leg: Unichain Sepolia (1301).
#
# Mirrors deploy.sh (Base Sepolia leg) on Unichain Sepolia:
#   Unichain Sepolia (1301): two Uniswap V2 venues, demo pair, GapHunterExecutor
#   Reactive Lasna (5318007): a SECOND GapHunterReactive with originChainId 1301
#
# Order differs slightly from deploy.sh on purpose: the RSC is deployed after
# pair creation but BEFORE seeding, so the seeding mint() Sync events teach it
# both pools' prices (no poke swap needed to arm the loop).
#
# Funding:
#   - wallet funded with Unichain Sepolia ETH (bridged from Ethereum Sepolia
#     via the canonical L1StandardBridge 0xea58fcA6849d79EAd1f26608855c2D6407d54Ce2,
#     deposit tx 0x3b61ac95e866ed09180b2ffea0d06ad69f1e01c65a779a499a48cd6b4a6f9e68)
#   - RSC2 funded with 0.25 lREACT (hard cap; RSC1's funds are not touched)
#
# The private key is read from ../evm-wallet.json and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

UNI_RPC="https://sepolia.unichain.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
UNI_PROXY="0x775c9B990ADe401060B78D0e98684eEf8d2466C1"
ADDR_FILE="deploy/addresses-unichain.json"

PK=$(python3 -c "import json;print(json.load(open('../evm-wallet.json'))['privateKey'])")
WALLET=$(cast wallet address --private-key "$PK")
echo "deployer: $WALLET"
echo "Unichain Sepolia ETH: $(cast balance "$WALLET" --rpc-url $UNI_RPC)"
echo "Lasna lREACT (wallet): $(cast balance "$WALLET" --rpc-url $LASNA_RPC)"

save() { python3 - "$@" <<'PY'
import json, sys
try: d = json.load(open('deploy/addresses-unichain.json'))
except Exception: d = {}
d[sys.argv[1]] = sys.argv[2]
json.dump(d, open('deploy/addresses-unichain.json', 'w'), indent=2)
PY
}
get() { python3 -c "import json;print(json.load(open('deploy/addresses-unichain.json'))['$1'])"; }
has() { [ -f "$ADDR_FILE" ] && grep -q "\"$1\"" "$ADDR_FILE"; }

# The public Unichain RPC is load-balanced and can return a stale nonce for
# back-to-back sends ("nonce too low"); wrap sends with retries.
send() { # $1 = rpc, rest = cast send args
  local rpc="$1"; shift
  local i
  for i in 1 2 3 4 5 6; do
    if cast send --rpc-url "$rpc" --private-key "$PK" "$@" >/dev/null 2>/tmp/send_err.txt; then
      return 0
    fi
    echo "send retry $i: $(cat /tmp/send_err.txt | head -c 200)" >&2
    sleep 3
  done
  echo "send FAILED permanently: $*" >&2
  return 1
}

deploy_factory() {
  local bin; bin=$(cat deploy/v2bytecode/UniswapV2Factory.bin)
  local args; args=$(cast abi-encode "constructor(address)" "$WALLET")
  local out; out=$(cast send --rpc-url $UNI_RPC --private-key "$PK" --create "${bin}${args#0x}" --json)
  echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])"
}

echo "== 1. Uniswap V2 factories (two venues) on Unichain Sepolia =="
if has factoryA; then
  FACTORY_A=$(get factoryA); FACTORY_B=$(get factoryB)
  echo "reusing factoryA: $FACTORY_A factoryB: $FACTORY_B"
else
  FACTORY_A=$(deploy_factory); save factoryA "$FACTORY_A"; echo "factoryA: $FACTORY_A"
  FACTORY_B=$(deploy_factory); save factoryB "$FACTORY_B"; echo "factoryB: $FACTORY_B"
fi

echo "== 2. Demo tokens =="
if has tokenA; then GTA=$(get tokenA); else GTA=$(forge create --broadcast src/MockERC20.sol:MockERC20 --rpc-url $UNI_RPC --private-key "$PK" --json --constructor-args "Gap Token A" "GTA" 18 | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"); save tokenA "$GTA"; fi
if has tokenB; then GTB=$(get tokenB); else GTB=$(forge create --broadcast src/MockERC20.sol:MockERC20 --rpc-url $UNI_RPC --private-key "$PK" --json --constructor-args "Gap Token B" "GTB" 18 | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"); save tokenB "$GTB"; fi
echo "GTA: $GTA  GTB: $GTB"

echo "== 3. Pairs (created, not yet seeded) =="
for F in "$FACTORY_A" "$FACTORY_B"; do
  EXISTING=$(cast call --rpc-url $UNI_RPC "$F" "getPair(address,address)(address)" "$GTA" "$GTB")
  if [ "$EXISTING" = "0x0000000000000000000000000000000000000000" ]; then
    cast send --rpc-url $UNI_RPC --private-key "$PK" "$F" "createPair(address,address)" "$GTA" "$GTB" >/dev/null
  fi
done
PAIR_A=$(cast call --rpc-url $UNI_RPC "$FACTORY_A" "getPair(address,address)(address)" "$GTA" "$GTB")
PAIR_B=$(cast call --rpc-url $UNI_RPC "$FACTORY_B" "getPair(address,address)(address)" "$GTA" "$GTB")
save pairA "$PAIR_A"; save pairB "$PAIR_B"; echo "pairA: $PAIR_A  pairB: $PAIR_B"
TOKEN0=$(cast call --rpc-url $UNI_RPC "$PAIR_A" "token0()(address)")
TOKEN1=$(cast call --rpc-url $UNI_RPC "$PAIR_A" "token1()(address)")
save token0 "$TOKEN0"; save token1 "$TOKEN1"; echo "token0: $TOKEN0  token1: $TOKEN1"

echo "== 4. GapHunterReactive #2 on Lasna (originChainId 1301), funded 0.25 lREACT =="
if has reactive; then
  RSC=$(get reactive); echo "reusing reactive: $RSC"
else
  RSC=$(forge create --broadcast src/GapHunterReactive.sol:GapHunterReactive --rpc-url $LASNA_RPC --private-key "$PK" --value 0.25ether --json --constructor-args 1301 "$PAIR_A" "$PAIR_B" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  save reactive "$RSC"; echo "reactive: $RSC"
fi

echo "== 5. Seed pairs (1,000,000 / 1,000,000 each) =="
for P in "$PAIR_A" "$PAIR_B"; do
  R0=$(cast call --rpc-url $UNI_RPC "$P" "getReserves()(uint112,uint112,uint32)" | head -1)
  if [ "$R0" = "0" ]; then
    send $UNI_RPC "$TOKEN0" "mint(address,uint256)" "$WALLET" 1000000000000000000000000
    send $UNI_RPC "$TOKEN1" "mint(address,uint256)" "$WALLET" 1000000000000000000000000
    send $UNI_RPC "$TOKEN0" "transfer(address,uint256)" "$P" 1000000000000000000000000
    send $UNI_RPC "$TOKEN1" "transfer(address,uint256)" "$P" 1000000000000000000000000
    send $UNI_RPC "$P" "mint(address)(uint256)" "$WALLET"
    echo "seeded $P"
  else
    echo "already seeded $P"
  fi
done

echo "== 6. GapHunterExecutor on Unichain Sepolia =="
if has executor; then
  EXEC=$(get executor); echo "reusing executor: $EXEC"
else
  EXEC=$(forge create --broadcast src/GapHunterExecutor.sol:GapHunterExecutor --rpc-url $UNI_RPC --private-key "$PK" --value 0.001ether --json --constructor-args "$UNI_PROXY" "$RSC" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  save executor "$EXEC"; echo "executor: $EXEC"
fi
send $LASNA_RPC "$RSC" "setExecutor(address)" "$EXEC"
echo "executor wired into RSC2"

echo "== 7. Fund executor with 500,000 token1 inventory =="
BAL=$(cast call --rpc-url $UNI_RPC "$TOKEN1" "balanceOf(address)(uint256)" "$EXEC")
if [ "$BAL" = "0" ]; then
  send $UNI_RPC "$TOKEN1" "mint(address,uint256)" "$EXEC" 500000000000000000000000
  echo "executor funded"
else
  echo "executor already holds token1: $BAL"
fi
save chainId 1301
save callbackProxy "$UNI_PROXY"
echo "DONE (Unichain deployment). Addresses in $ADDR_FILE"
echo "Unichain Sepolia ETH left: $(cast balance "$WALLET" --rpc-url $UNI_RPC)"
echo "Lasna lREACT (wallet) left: $(cast balance "$WALLET" --rpc-url $LASNA_RPC)"
echo "RSC2 lREACT balance: $(cast balance "$RSC" --rpc-url $LASNA_RPC)"
