#!/usr/bin/env bash
# Recovery for the existing Base deployment only; never creates new contracts.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BASE_RPC_URL:?Source .env first}"
[[ -z "${AERO_FORK_BLOCK:-}" ]] || { echo 'Unset AERO_FORK_BLOCK before recovery.' >&2; exit 2; }
mode="${1:---dry-run}"
artifact=broadcast/CompleteAeroProtocolDeployment.s.sol/8453/run-latest.json
case "$mode" in
  --dry-run) args=() ;;
  --broadcast)
    [[ ! -f "$artifact" ]] || { echo 'Recovery record already exists; inspect receipts before any retry.' >&2; exit 2; }
    args=(--broadcast --slow --account deployer) ;;
  *) echo 'Usage: bash script/complete-aero-deployment.sh [--dry-run|--broadcast]' >&2; exit 2 ;;
esac
forge script script/CompleteAeroProtocolDeployment.s.sol:CompleteAeroProtocolDeployment \
  --rpc-url "$BASE_RPC_URL" --sender 0x83681C14770b44361e21Faf91D8325423365eA5C \
  --gas-estimate-multiplier 200 "${args[@]}" -vv
