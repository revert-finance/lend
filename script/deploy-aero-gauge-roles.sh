#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---dry-run}"
if [[ -z "${BASE_RPC_URL:-}" && -n "${ALCHEMY_API_KEY:-}" ]]; then
  export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
fi
: "${BASE_RPC_URL:?Set BASE_RPC_URL or ALCHEMY_API_KEY}"
: "${AERO_GAUGE_DEPLOYER:?Set the deployment EOA public address}"
: "${AERO_GAUGE_OPERATOR:?Set a separate dedicated automation EOA public address}"
: "${AERO_GAUGE_ROLES_SALT:?Set a fresh numeric deployment salt}"
args=(--sender "$AERO_GAUGE_DEPLOYER")
case "$mode" in
  --dry-run) ;;
  --broadcast|--resume)
    : "${AERO_GAUGE_DEPLOYER_ACCOUNT:?Set the Foundry deployment keystore account}"
    args+=(--broadcast --slow --account "$AERO_GAUGE_DEPLOYER_ACCOUNT")
    if [[ "$mode" == --resume ]]; then args+=(--resume); fi ;;
  *) echo 'Usage: bash script/deploy-aero-gauge-roles.sh [--dry-run|--broadcast|--resume]' >&2; exit 2 ;;
esac
printf '%s\n' 'Deploy inactive Zodiac Roles and gauge validator. Safe activation is a separate transaction.'
forge script script/DeployAeroGaugeRoles.s.sol:DeployAeroGaugeRoles --rpc-url "$BASE_RPC_URL" "${args[@]}" -vv
