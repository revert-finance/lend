#!/usr/bin/env bash
# Rehearse first; only --broadcast sends transactions. Signing stays in the local Foundry keystore.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BASE_RPC_URL:?Set BASE_RPC_URL to a Base RPC with historical-state support}"
export AERO_DEPLOYER=0x83681C14770b44361e21Faf91D8325423365eA5C
mode="${1:---dry-run}"
case "$mode" in
  --dry-run) args=() ;;
  --broadcast) args=(--broadcast --slow --account deployer) ;;
  --resume) args=(--resume --broadcast --slow --account deployer) ;;
  --verify) args=(--resume --verify); : "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY}" ;;
  *) echo 'Usage: bash script/deploy-aero-protocol.sh [--dry-run|--broadcast|--resume|--verify]' >&2; exit 2 ;;
esac
artifact=broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json
if [[ "$mode" == --broadcast && -f "$artifact" ]]; then
  echo 'Existing deployment record found. Inspect receipts and use --resume for that sequence; do not redeploy blindly.' >&2
  exit 2
fi
if [[ "$mode" == --resume || "$mode" == --verify ]]; then
  [[ -f "$artifact" ]] || { echo 'No saved deployment sequence to resume/verify.' >&2; exit 2; }
fi
# For deterministic rehearsal set AERO_FORK_BLOCK; never pin production execution to an old block.
if [[ -n "${AERO_FORK_BLOCK:-}" ]]; then
  [[ "$mode" == --dry-run ]] || { echo 'Unset AERO_FORK_BLOCK before broadcast/resume/verify.' >&2; exit 2; }
  args+=(--fork-block-number "$AERO_FORK_BLOCK")
fi
printf '%s\n' 'Base: fresh Aero protocol. Initial debt cap 0; Safe acceptance and activation are separate.'
forge script script/DeployAeroProtocol.s.sol:DeployAeroProtocol \
  --rpc-url "$BASE_RPC_URL" --sender "$AERO_DEPLOYER" "${args[@]}" -vv
