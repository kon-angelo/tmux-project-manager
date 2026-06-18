#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# carousel.sh — Cycle through the project session's working windows.
# Sequence (within the current project session):
#   claude  →  editor  →  last shell  →  claude  →  ...
#
# Definitions:
#   - "last shell" is the highest-indexed window that is neither $TPM_WINDOW_TOOL
#     nor $TPM_WINDOW_EDITOR. If no such window exists when the carousel reaches
#     this slot, a new window named "shell" is created (cwd = project path) and
#     selected.
#   - If a project has the editor window disabled (nvim: false), the editor
#     slot is skipped: claude → shell → claude.
#
# Behaviour outside a project-managed session: silent no-op.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
[[ -z "$session_name" ]] && exit 0

if ! is_managed_session "$session_name"; then
  exit 0
fi

project_key=$(get_session_project_key "$session_name") || true
[[ -z "$project_key" ]] && exit 0

project_path=$(get_path "$project_key")

# Locate (or create) the "last shell" window — the highest-indexed window
# whose name is neither claude nor editor. Prints the resolved window name on
# success.
go_to_shell() {
  local last_name
  last_name=$(tmux list-windows -t "=$session_name" \
                -F '#{window_index} #{window_name}' 2>/dev/null \
              | sort -n -k1 \
              | awk -v t="$TPM_WINDOW_TOOL" -v e="$TPM_WINDOW_EDITOR" \
                  '$2 != t && $2 != e { name = $2 } END { print name }')

  if [[ -z "$last_name" ]]; then
    # No shell window exists — create one at the end of the session.
    tmux new-window -t "=$session_name" -n "shell" -c "$project_path"
    last_name="shell"
  fi
  tmux select-window -t "=$session_name:$last_name"
}

current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null || echo "")

case "$current_window" in
  "$TPM_WINDOW_TOOL")
    # claude → editor (or skip to shell if editor disabled / missing)
    if has_editor "$project_key" && window_exists "$session_name" "$TPM_WINDOW_EDITOR"; then
      tmux select-window -t "=$session_name:$TPM_WINDOW_EDITOR"
    else
      go_to_shell
    fi
    ;;

  "$TPM_WINDOW_EDITOR")
    # editor → last shell (creating one if needed)
    go_to_shell
    ;;

  *)
    # any shell / task-worker / other window → claude
    if window_exists "$session_name" "$TPM_WINDOW_TOOL"; then
      tmux select-window -t "=$session_name:$TPM_WINDOW_TOOL"
    fi
    ;;
esac
