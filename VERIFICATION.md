# Contract verification

Both GapHunter contracts are verified on **Sourcify** with an
**exact match** — Sourcify recompiled the sources in this repository and
the resulting creation and runtime bytecode are identical to what is
deployed, metadata hash included.

| Contract | Chain | Address | Sourcify |
| --- | --- | --- | --- |
| `GapHunterExecutor` | Base Sepolia (84532) | `0x986249121a4453294A68f6c7Cbc250Db6d30bF63` | [exact_match](https://repo.sourcify.dev/84532/0x986249121a4453294A68f6c7Cbc250Db6d30bF63) |
| `GapHunterReactive` | Reactive Lasna (5318007) | `0x33BB79402a0802bE06D8b9F2b6171e80e54B3222` | [exact_match](https://repo.sourcify.dev/5318007/0x33BB79402a0802bE06D8b9F2b6171e80e54B3222) |

Machine-readable status (Sourcify v2 API):

- https://sourcify.dev/server/v2/contract/84532/0x986249121a4453294A68f6c7Cbc250Db6d30bF63
  → `match: exact_match`, `creationMatch: exact_match`,
  `runtimeMatch: exact_match`, verified 2026-11-25T12:00:53Z
  (job `85cddaa3-2266-4814-8c80-9b1d9814d289`).
- https://sourcify.dev/server/v2/contract/5318007/0x33BB79402a0802bE06D8b9F2b6171e80e54B3222
  → `match: exact_match`, `creationMatch: exact_match`,
  `runtimeMatch: exact_match`, verified 2026-11-25T12:01:20Z
  (job `df9d960f-a81b-4d50-9a0d-dd56017411c9`).

The executor also shows as verified on the Base Sepolia Blockscout
explorer, which mirrors the Sourcify result:
https://base-sepolia.blockscout.com/address/0x986249121a4453294A68f6c7Cbc250Db6d30bF63

## How it was done

```bash
forge verify-contract 0x986249121a4453294A68f6c7Cbc250Db6d30bF63 \
  src/GapHunterExecutor.sol:GapHunterExecutor --chain 84532 \
  --verifier sourcify \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x476F44b11F5C942c58f4c8E3d0300E5710743585 \
    0x33BB79402a0802bE06D8b9F2b6171e80e54B3222)

forge verify-contract 0x33BB79402a0802bE06D8b9F2b6171e80e54B3222 \
  src/GapHunterReactive.sol:GapHunterReactive --chain 5318007 \
  --verifier sourcify \
  --constructor-args $(cast abi-encode "constructor(uint256,address,address)" \
    84532 \
    0x633ECDA3DFDE4e508Be2c2807117B5Bc868019C3 \
    0x8e62F00356C75791570182bB1A412BC4129f387a)
```

(Constructor arguments are the deployment values from `deploy/deploy.sh`:
the Base Sepolia callback proxy and the reactive contract for the
executor; the origin chain id and the two pool addresses for the
reactive contract.)

## Verify it yourself (no explorer needed)

```bash
bash script/verify-deployment.sh
```

The script recompiles the project, fetches each contract's deployed
runtime bytecode with `cast code`, patches the locally compiled
bytecode's immutable-variable regions with the values found on-chain
(immutables are baked into runtime code by the constructor, so the raw
compiler artifact carries zeros in those slots), and compares the two
byte-for-byte, CBOR metadata hash included. Current output:

```
GapHunterExecutor @ 0x986249121a4453294A68f6c7Cbc250Db6d30bF63: MATCH (3875 bytes, byte-for-byte incl. metadata hash)
GapHunterReactive @ 0x33BB79402a0802bE06D8b9F2b6171e80e54B3222: MATCH (3874 bytes, byte-for-byte incl. metadata hash)
```

One caveat for completeness: `forge verify-bytecode` was also tried and
reported a mismatch for both contracts despite the byte-for-byte
equality above (it appears to mishandle the immutable regions of this
via-IR build). The direct comparison in `script/verify-deployment.sh`
and Sourcify's independent recompilation both agree the deployments
match this source exactly.
