#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export AERO_DEPLOYER=0x83681C14770b44361e21Faf91D8325423365eA5C
mode="${1:---dry-run}"
case "$mode" in
  --dry-run) args=() ;;
  --broadcast) args=(--broadcast --slow --account deployer --gas-estimate-multiplier 200) ;;
  --resume) args=(--resume --broadcast --slow --account deployer --gas-estimate-multiplier 200) ;;
  --verify) exec python3 script/verify-poolside-factory.py ;;
  *) echo 'Usage: bash script/deploy-poolside-factory.sh [--dry-run|--broadcast|--resume|--verify]' >&2; exit 2 ;;
esac
if [[ -z "${BASE_RPC_URL:-}" && -n "${ALCHEMY_API_KEY:-}" ]]; then
  export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
fi
: "${BASE_RPC_URL:?Set BASE_RPC_URL or ALCHEMY_API_KEY}"
record=broadcast/DeployPoolsideFactory.s.sol/8453/run-latest.json
if [[ "$mode" == --broadcast && -f "$record" ]]; then
  echo 'Deployment record already exists. Inspect receipts before using --resume; do not redeploy blindly.' >&2
  exit 2
fi
if [[ "$mode" == --resume && ! -f "$record" ]]; then
  echo 'No saved deployment to resume.' >&2
  exit 2
fi
if [[ -n "${AERO_FORK_BLOCK:-}" ]]; then
  [[ "$mode" == --dry-run ]] || { echo 'Unset AERO_FORK_BLOCK before broadcasting.' >&2; exit 2; }
  args+=(--fork-block-number "$AERO_FORK_BLOCK")
fi
printf '%s\n' 'Base: deploy Simple-fee Poolside factory and authorize it in existing AutoExit.' \
  'Keep Base bots using the deployer account paused throughout broadcast/resume to avoid nonce collisions.'
forge script script/DeployPoolsideFactory.s.sol:DeployPoolsideFactory \
  --rpc-url "$BASE_RPC_URL" --sender "$AERO_DEPLOYER" "${args[@]}" -vv
