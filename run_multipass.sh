#!/usr/bin/env bash
set -euo pipefail

N="${1:-}"
INIT="${2:-audit_prompt.md}"

if [[ -z "${N}" ]]; then
  echo "Usage: $0 N [initial_prompt_md]" >&2
  exit 1
fi

# Turn 1
#time codex exec --json --full-auto - < "$INIT" > t01.jsonl 2> t01.err

# Turns 2..N
for ((i=7; i<=N; i++)); do
  printf -v ii "%02d" "$i"

  time codex exec resume --last --json --full-auto - <<EOF > "t${ii}.jsonl" 2> "t${ii}.err"
PASS ${i}: Refute the prior findings. For each top 40 risk items, try to disprove them by locating concrete defenses in code.
Add/modify Foundry tests to validate/refute each hypothesis, and re-run forge test.
Update audit/ artifacts accordingly.
EOF

done
