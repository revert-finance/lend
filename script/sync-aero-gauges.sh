#!/usr/bin/env bash
# --safe remains read-only. --roles-broadcast uses the separately authorized registration EOA.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---safe}"
: "${AERO_GAUGE_MANAGER:?Set AERO_GAUGE_MANAGER to the intended deployed GaugeManager}"
if [[ -z "${BASE_RPC_URL:-}" && -n "${ALCHEMY_API_KEY:-}" ]]; then
  export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
fi
: "${BASE_RPC_URL:?Set BASE_RPC_URL or ALCHEMY_API_KEY}"
export AERO_GAUGE_SYNC_SAFE=false
export AERO_GAUGE_SYNC_ROLES=false
args=(--sender "${AERO_GAUGE_SENDER:-0x83681C14770b44361e21Faf91D8325423365eA5C}")
case "$mode" in
  --safe) export AERO_GAUGE_SYNC_SAFE=true ;;
  --roles-dry-run|--roles-broadcast)
    : "${AERO_GAUGE_ROLES:?Set the deployed Roles instance}"
    : "${AERO_GAUGE_CONDITION:?Set the deployed registration condition}"
    : "${AERO_GAUGE_OPERATOR:?Set the dedicated registration EOA}"
    export AERO_GAUGE_SYNC_ROLES=true
    args=(--sender "$AERO_GAUGE_OPERATOR")
    if [[ "$mode" == --roles-broadcast ]]; then
      : "${AERO_GAUGE_OPERATOR_ACCOUNT:?Set the dedicated Foundry keystore account}"
      args+=(--broadcast --slow --account "$AERO_GAUGE_OPERATOR_ACCOUNT")
    fi ;;
  --dry-run|--broadcast)
    export AERO_GAUGE_SENDER="${AERO_GAUGE_SENDER:-0x83681C14770b44361e21Faf91D8325423365eA5C}"
    if [[ "$mode" == --broadcast ]]; then
      args+=(--broadcast --slow --account "${AERO_GAUGE_ACCOUNT:-deployer}")
      echo 'Keep bots sharing the signer account paused during broadcast. Re-run --safe after any partial failure.'
    fi ;;
  *) echo 'Usage: bash script/sync-aero-gauges.sh [--safe|--dry-run|--broadcast|--roles-dry-run|--roles-broadcast]' >&2; exit 2 ;;
esac
if [[ -n "${AERO_FORK_BLOCK:-}" ]]; then
  [[ "$mode" != --broadcast && "$mode" != --roles-broadcast ]] || { echo 'Unset AERO_FORK_BLOCK before broadcast.' >&2; exit 2; }
  args+=(--fork-block-number "$AERO_FORK_BLOCK")
fi
forge script script/SyncAeroGauges.s.sol:SyncAeroGauges --rpc-url "$BASE_RPC_URL" "${args[@]}" -vv
