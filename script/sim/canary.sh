#!/usr/bin/env bash
# Transfer canary (plan WP3 bucket 2 / WP6): simulated B20 transfers with `from` overrides, executed
# by the live node (native B20 code). Any revert or `false` means transfer gating changed.
# Directions per token: pool -> fresh EOA, pool -> V3Utils, pool -> multisig, other pool -> pool,
# plus pool -> $VAULT and pool -> each $WATCH_ADDRESSES entry once they exist.
# Output: out/canary-<block>.json ; exit 1 on any failure.
source "$(dirname "$0")/common.sh"

FRESH_EOA=0x00000000000000000000000000000000DeaDBeef
AMOUNT=1  # 1e-8 token

out="$OUT_DIR/canary-$BLOCK.json"
fail=0
prev_pool=""
{
  echo "{\"block\":$BLOCK,\"timestamp\":$NOW,\"transfers\":["
  first=1
  for e in "${EQUITIES[@]}"; do
    read -r sym token _ pool <<<"$e"
    targets=("$FRESH_EOA" "$V3_UTILS" "$BASE_MULTISIG")
    [ -n "${VAULT:-}" ] && targets+=("$VAULT")
    for a in ${WATCH_ADDRESSES:-}; do targets+=("$a"); done
    for to in "${targets[@]}"; do
      if res=$(ccall "$token" "transfer(address,uint256)(bool)" "$to" "$AMOUNT" --from "$pool" 2>&1); then ok=$res; else ok="\"revert\""; fi
      [ "$ok" = "true" ] || fail=1
      [ $first -eq 1 ] || echo ","; first=0
      echo "{\"symbol\":\"$sym\",\"from\":\"$pool\",\"fromKind\":\"pool\",\"to\":\"$to\",\"ok\":$ok}"
    done
    # receiver = pool: send from the pool itself (pool -> pool) so the sender is a known holder
    if res=$(ccall "$token" "transfer(address,uint256)(bool)" "$pool" "$AMOUNT" --from "$pool" 2>&1); then ok=$res; else ok="\"revert\""; fi
    [ "$ok" = "true" ] || fail=1
    echo ",{\"symbol\":\"$sym\",\"from\":\"$pool\",\"fromKind\":\"pool\",\"to\":\"$pool\",\"toKind\":\"pool\",\"ok\":$ok}"
  done
  echo "]}"
} > "$out"
python3 -c "
import json; d=json.load(open('$out'))
bad=[t for t in d['transfers'] if t['ok'] is not True]
print(f\"block {d['block']}: {len(d['transfers'])} simulated transfers, {len(bad)} failing\")
for t in bad: print('  FAIL', t)"
echo "written $out"
[ $fail -eq 0 ] && echo "OK: every simulated transfer returned true" || { echo "ALERT: transfer gating changed"; exit 1; }
