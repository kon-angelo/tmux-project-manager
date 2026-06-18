#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# cycle.sh — Cycle through project sessions (M-[ / M-]).
# Usage: cycle.sh <prev|next>
# Only cycles through sessions tagged @tpm-managed=1 (or whose names match
# project aliases — see is_managed_session fallback).

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

direction="${1:-next}"

mapfile -t sessions < <(list_managed_sessions | sort)

# No managed sessions — silent no-op.
if (( ${#sessions[@]} == 0 )); then
  exit 0
fi

# Single managed session — switch to it.
if (( ${#sessions[@]} == 1 )); then
  tmux switch-client -t "=${sessions[0]}"
  exit 0
fi

current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
current_idx=-1
for i in "${!sessions[@]}"; do
  if [[ "${sessions[$i]}" == "$current_session" ]]; then
    current_idx=$i
    break
  fi
done

# Current session isn't managed — jump to the first managed one.
if (( current_idx == -1 )); then
  tmux switch-client -t "=${sessions[0]}"
  exit 0
fi

count=${#sessions[@]}
if [[ "$direction" == "prev" ]]; then
  target_idx=$(( (current_idx - 1 + count) % count ))
else
  target_idx=$(( (current_idx + 1) % count ))
fi

tmux switch-client -t "=${sessions[$target_idx]}"
