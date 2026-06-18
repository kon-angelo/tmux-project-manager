#!/usr/bin/env bash
# cycle.sh — Cycle through project sessions (M-[ / M-]).
# Usage: cycle.sh <prev|next>
# Only cycles through sessions tagged @tpm-managed=1.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

direction="${1:-next}"

# Get all managed sessions (sorted by name)
mapfile -t sessions < <(list_managed_sessions | sort)

# No managed sessions — no-op
if (( ${#sessions[@]} == 0 )); then
  exit 0
fi

# Only one session — no-op (already there or switch to it)
if (( ${#sessions[@]} == 1 )); then
  tmux switch-client -t "=${sessions[0]}"
  exit 0
fi

# Find current session in the list
current_session=$(tmux display-message -p '#{session_name}')
current_idx=-1
for i in "${!sessions[@]}"; do
  if [[ "${sessions[$i]}" == "$current_session" ]]; then
    current_idx=$i
    break
  fi
done

# If current session is not a managed one, jump to first managed session
if (( current_idx == -1 )); then
  tmux switch-client -t "=${sessions[0]}"
  exit 0
fi

# Calculate target index
count=${#sessions[@]}
if [[ "$direction" == "prev" ]]; then
  target_idx=$(( (current_idx - 1 + count) % count ))
else
  target_idx=$(( (current_idx + 1) % count ))
fi

tmux switch-client -t "=${sessions[$target_idx]}"
