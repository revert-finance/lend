#!/usr/bin/env bash
# B20 policy observability (plan WP1.3 / WP6 poller).
# For each equity: policyId(scope) for all six scopes; for each policy id: policyExists, policyAdmin,
# pendingPolicyAdmin and isAuthorized(id, x) for every protocol address we depend on.
# Extra addresses (vault, oracle, liquidators...) via WATCH_ADDRESSES="0x.. 0x.." once they exist.
# Output: out/policy_registry-<block>.json ; exit 1 if any watched address is unauthorized.
source "$(dirname "$0")/common.sh"

SCOPES=(TRANSFER_SENDER_POLICY TRANSFER_RECEIVER_POLICY TRANSFER_EXECUTOR_POLICY MINT_RECEIVER_POLICY SEIZE_EXEMPT_POLICY SEIZE_RECEIVER_POLICY)
FRESH_EOA=0x00000000000000000000000000000000DeaDBeef

watch=("$AERODROME_NPM" "$V3_UTILS" "$BASE_MULTISIG" "$FRESH_EOA")
for e in "${EQUITIES[@]}"; do read -r _ _ _ pool <<<"$e"; watch+=("$pool"); done
for a in ${WATCH_ADDRESSES:-}; do watch+=("$a"); done

out="$OUT_DIR/policy_registry-$BLOCK.json"
fail=0
{
  echo "{\"block\":$BLOCK,\"timestamp\":$NOW,\"registry\":\"$B20_POLICY_REGISTRY\",\"tokens\":["
  first_tok=1
  for e in "${EQUITIES[@]}"; do
    read -r sym token _ _ <<<"$e"
    [ $first_tok -eq 1 ] || echo ","; first_tok=0
    echo "{\"symbol\":\"$sym\",\"token\":\"$token\",\"scopes\":{"
    first=1
    declare -A ids=()
    for s in "${SCOPES[@]}"; do
      key=$(cast keccak "$s")
      if id=$(ccall "$token" "policyId(bytes32)(uint64)" "$key" 2>/dev/null); then v="$id"; ids[$id]=1; else v="null"; fi
      [ $first -eq 1 ] || echo ","; first=0
      echo "\"$s\":$v"
    done
    echo "},\"policies\":{"
    first=1
    for id in "${!ids[@]}"; do
      exists=$(ccall "$B20_POLICY_REGISTRY" "policyExists(uint64)(bool)" "$id")
      admin=$(ccall "$B20_POLICY_REGISTRY" "policyAdmin(uint64)(address)" "$id")
      pending=$(ccall "$B20_POLICY_REGISTRY" "pendingPolicyAdmin(uint64)(address)" "$id")
      admin_code=$(cast code "$admin" --rpc-url "$BASE_RPC_URL" | wc -c)
      [ $first -eq 1 ] || echo ","; first=0
      echo "\"$id\":{\"exists\":$exists,\"admin\":\"$admin\",\"adminHasCode\":$([ "$admin_code" -gt 3 ] && echo true || echo false),\"pendingAdmin\":\"$pending\",\"authorized\":{"
      firsta=1
      for w in "${watch[@]}"; do
        ok=$(ccall "$B20_POLICY_REGISTRY" "isAuthorized(uint64,address)(bool)" "$id" "$w")
        [ $firsta -eq 1 ] || echo ","; firsta=0
        echo "\"$w\":$ok"
        [ "$ok" = "true" ] || fail=1
      done
      echo "}}"
    done
    unset ids
    echo "}}"
  done
  echo "]}"
} > "$out"
python3 -c "import json,sys; d=json.load(open('$out')); print(json.dumps(d, indent=1))" | head -60
echo "written $out"
if [ $fail -ne 0 ]; then echo "ALERT: an address is NOT authorized"; exit 1; fi
echo "OK: all watched addresses authorized on every policy"
