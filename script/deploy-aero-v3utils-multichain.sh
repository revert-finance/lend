#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
network="${1:-}"
mode="${2:---dry-run}"
[[ $# -le 2 ]] || { echo 'Too many arguments' >&2; exit 2; }
case "$network" in
  mainnet)
    export AERO_CHAIN_ID=1
    rpc="${MAINNET_RPC_URL:-}"
    if [[ -z "$rpc" && -n "${ALCHEMY_API_KEY:-}" ]]; then
      rpc="https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    fi
    ;;
  robinhood)
    export AERO_CHAIN_ID=4663
    rpc="${ROBINHOOD_RPC_URL:-}"
    if [[ -z "$rpc" && -n "${ALCHEMY_API_KEY:-}" ]]; then
      rpc="https://robinhood-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    fi
    rpc="${rpc:-https://rpc.mainnet.chain.robinhood.com}"
    ;;
  *) echo 'Usage: bash script/deploy-aero-v3utils-multichain.sh mainnet|robinhood [--dry-run|--broadcast|--resume|--verify]' >&2; exit 2 ;;
esac
export AERO_RPC_URL="${rpc:?Set MAINNET_RPC_URL or ALCHEMY_API_KEY}"
export AERO_DEPLOYER=0x83681C14770b44361e21Faf91D8325423365eA5C
record="broadcast/DeployAeroV3UtilsMultichain.s.sol/$AERO_CHAIN_ID/run-latest.json"
case "$mode" in
  --dry-run) args=() ;;
  --broadcast)
    [[ ! -f "$record" ]] || { echo 'A deployment record exists. Inspect receipts before --resume; do not redeploy blindly.' >&2; exit 2; }
    args=(--broadcast --slow --account deployer --gas-estimate-multiplier 150) ;;
  --resume)
    [[ -f "$record" ]] || { echo 'No saved deployment to resume.' >&2; exit 2; }
    args=(--resume --broadcast --slow --account deployer --gas-estimate-multiplier 150) ;;
  --verify) exec python3 script/verify-aero-v3utils-multichain.py ;;
  *) echo 'Unknown mode' >&2; exit 2 ;;
esac
: "${AERO_V3UTILS_OWNER:?Set AERO_V3UTILS_OWNER to the approved final owner for this network}"
if [[ -n "${AERO_FORK_BLOCK:-}" ]]; then
  [[ "$mode" == --dry-run ]] || { echo 'Unset AERO_FORK_BLOCK before broadcast/resume.' >&2; exit 2; }
  args+=(--fork-block-number "$AERO_FORK_BLOCK")
fi
printf '%s\n' "$network: deploy standalone Aero V3Utils and nominate $AERO_V3UTILS_OWNER as owner." \
  'Pause other transactions from deployer on this chain during broadcast/resume. Ownership acceptance is separate.'
forge script script/DeployAeroV3UtilsMultichain.s.sol:DeployAeroV3UtilsMultichain \
  --rpc-url "$AERO_RPC_URL" --sender "$AERO_DEPLOYER" "${args[@]}" -vv
