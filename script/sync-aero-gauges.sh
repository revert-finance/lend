#!/usr/bin/env bash
# --safe is read-only and suitable for periodic invocation. No unattended wallet signing.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---safe}"
: "${AERO_GAUGE_MANAGER:?Set AERO_GAUGE_MANAGER to the intended deployed GaugeManager}"
if [[ -z "${BASE_RPC_URL:-}" && -n "${ALCHEMY_API_KEY:-}" ]]; then
  export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
fi
: "${BASE_RPC_URL:?Set BASE_RPC_URL or ALCHEMY_API_KEY}"
export AERO_GAUGE_SYNC_SAFE=false
args=(--sender "${AERO_GAUGE_SENDER:-0x83681C14770b44361e21Faf91D8325423365eA5C}")
case "$mode" in
  --safe) export AERO_GAUGE_SYNC_SAFE=true ;;
  --dry-run|--broadcast)
    export AERO_GAUGE_SENDER="${AERO_GAUGE_SENDER:-0x83681C14770b44361e21Faf91D8325423365eA5C}"
    if [[ "$mode" == --broadcast ]]; then
      args+=(--broadcast --slow --account "${AERO_GAUGE_ACCOUNT:-deployer}")
      echo 'Keep bots sharing the signer account paused during broadcast. Re-run --safe after any partial failure.'
    fi ;;
  *) echo 'Usage: bash script/sync-aero-gauges.sh [--safe|--dry-run|--broadcast]' >&2; exit 2 ;;
esac
if [[ -n "${AERO_FORK_BLOCK:-}" ]]; then
  [[ "$mode" != --broadcast ]] || { echo 'Unset AERO_FORK_BLOCK before broadcast.' >&2; exit 2; }
  args+=(--fork-block-number "$AERO_FORK_BLOCK")
fi
forge script script/SyncAeroGauges.s.sol:SyncAeroGauges --rpc-url "$BASE_RPC_URL" "${args[@]}" -vv
