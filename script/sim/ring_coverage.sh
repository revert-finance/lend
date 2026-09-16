#!/usr/bin/env bash
# TWAP liveness gate (plan WP0.1 / WP6): observe([TWAP_SECONDS, 0]) must succeed on every pool and the
# oldest stored observation must be >= COVERAGE_MULT * TWAP_SECONDS old. Cardinality is informational.
# Output: out/ring_coverage-<block>.json ; exit 1 on any gate failure.
source "$(dirname "$0")/common.sh"
COVERAGE_MULT="${COVERAGE_MULT:-10}"

out="$OUT_DIR/ring_coverage-$BLOCK.json"
fail=0
{
  echo "{\"block\":$BLOCK,\"timestamp\":$NOW,\"twapSeconds\":$TWAP_SECONDS,\"requiredCoverageSeconds\":$((TWAP_SECONDS*COVERAGE_MULT)),\"pools\":["
  first=1
  for e in "${EQUITIES[@]}"; do
    read -r sym _ _ pool <<<"$e"
    slot0=$(ccall "$pool" "slot0()(uint160,int24,uint16,uint16,uint16,bool)" | awk '{print $1}')
    idx=$(echo "$slot0" | sed -n 3p); card=$(echo "$slot0" | sed -n 4p); next=$(echo "$slot0" | sed -n 5p)
    if ccall "$pool" "observe(uint32[])(int56[],uint160[])" "[$TWAP_SECONDS,0]" >/dev/null 2>&1; then observe_ok=true; else observe_ok=false; fail=1; fi
    # oldest initialized observation: the slot after the current index (ring order)
    oldest=$(( (idx + 1) % card ))
    obs=$(ccall "$pool" "observations(uint256)(uint32,int56,uint160,bool)" "$oldest" | awk '{print $1}')
    ts=$(echo "$obs" | sed -n 1p); init=$(echo "$obs" | sed -n 4p)
    if [ "$init" != "true" ]; then obs=$(ccall "$pool" "observations(uint256)(uint32,int56,uint160,bool)" 0 | awk '{print $1}'); ts=$(echo "$obs" | sed -n 1p); fi
    coverage=$((NOW - ts))
    gate=true; [ "$coverage" -ge $((TWAP_SECONDS*COVERAGE_MULT)) ] || { gate=false; fail=1; }
    [ $first -eq 1 ] || echo ","; first=0
    echo "{\"symbol\":\"$sym\",\"pool\":\"$pool\",\"observationIndex\":$idx,\"cardinality\":$card,\"cardinalityNext\":$next,\"observeOk\":$observe_ok,\"oldestObservationAgeSeconds\":$coverage,\"coverageGate\":$gate}"
  done
  echo "]}"
} > "$out"
python3 -c "
import json; d=json.load(open('$out'))
print(f\"block {d['block']}  twap {d['twapSeconds']}s  required coverage {d['requiredCoverageSeconds']}s\")
for p in d['pools']: print(f\"{p['symbol']:7} card {p['cardinality']:5} observe={p['observeOk']!s:5} oldest={p['oldestObservationAgeSeconds']:>8}s gate={p['coverageGate']}\")"
echo "written $out"
[ $fail -eq 0 ] && echo "OK: TWAP gate green on all pools" || { echo "ALERT: TWAP gate failed"; exit 1; }
