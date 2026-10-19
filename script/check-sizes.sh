#!/usr/bin/env bash
# Size guard for V3Vault (EIP-170 runtime limit: 24,576 bytes).
#
# V3Vault's via-IR bytecode depends on the set of files compiled together with it, so the full build and the
# source-only build (--skip test --skip script) give different sizes, and incremental builds give other numbers
# again. This script therefore runs BOTH modes as forced clean builds and fails if the vault exceeds the guard
# limit in either of them. Run it from a normal checkout (symlinked scratch trees mislead as well).
#
# Usage: script/check-sizes.sh            (limit defaults to 24,320 bytes = 256 under EIP-170, override with V3VAULT_SIZE_LIMIT)
set -euo pipefail

cd "$(dirname "$0")/.."

LIMIT="${V3VAULT_SIZE_LIMIT:-24320}"
EIP170_LIMIT=24576
CONTRACT="V3Vault"
status=0

runtime_size() {
    # prints the runtime size of $CONTRACT from `forge build --force --sizes --json <mode flags>`
    # (forge exits non-zero when any contract is above the EIP-170 limit, the report is still printed)
    local json
    json="$(forge build --force --sizes --json "$@" 2>/dev/null || true)"
    local size
    size="$(printf '%s' "$json" | grep -o "\"$CONTRACT\":{\"runtime_size\":[0-9]*" | grep -o '[0-9]*$' || true)"
    if [[ -z "$size" ]]; then
        echo "error: no size report for $CONTRACT (build failed?), rerun: forge build --force --sizes $*" >&2
        exit 2
    fi
    printf '%s' "$size"
}

check() {
    local label="$1"
    shift
    local size
    size="$(runtime_size "$@")"
    local verdict="ok"
    if (( size > LIMIT )); then
        verdict="FAIL"
        status=1
    fi
    printf '%-32s %6d bytes  (guard %d, EIP-170 margin %6d)  %s\n' \
        "$label" "$size" "$LIMIT" "$((EIP170_LIMIT - size))" "$verdict"
}

echo "$CONTRACT runtime size, forced clean builds:"
check "source only (--skip test/script)" --skip test --skip script
check "full (tests and scripts)"

if (( status != 0 )); then
    echo "error: $CONTRACT exceeds the size guard of $LIMIT bytes" >&2
fi
exit "$status"
