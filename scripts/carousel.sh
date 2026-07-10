#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# carousel.sh — Cycle through the project session's working windows.
# Sequence (within the current project session):
#   claude  →  editor  →  shell  →  claude  →  ...
#
# "Back to shell" returns to whichever shell window the user was in before
# entering the claude/editor leg. The originating window ID is saved in the
# session-scoped option @tpm-carousel-origin when leaving a shell window.
# If that window no longer exists, falls back to the highest-indexed shell
# window (or creates one).
#
# Definitions:
#   - If a project has the editor window disabled (nvim: false), the editor
#     slot is skipped: claude → shell → claude.
#
# Behaviour outside a project-managed session: silent no-op.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

load_projects_cache

session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
[[ -z "$session_name" ]] && exit 0

if ! is_managed_session "$session_name"; then
  exit 0
fi

project_key=$(get_session_project_key "$session_name") || true
[[ -z "$project_key" ]] && exit 0

project_path=$(get_path "$project_key")

# Return to the shell window the user was in before the carousel entered the
# tool/editor leg. Uses the saved @tpm-carousel-origin window ID if it still
# exists; otherwise falls back to the highest-indexed non-tool/non-editor
# window, creating a new "shell" window as a last resort.
go_to_shell() {
  # 1. Try the saved origin window.
  local origin_id
  origin_id=$(tmux show-option -t "=$session_name:" -qv "@tpm-carousel-origin" 2>/dev/null || true)
  if [[ -n "$origin_id" ]]; then
    # Verify the window still exists in this session.
    if tmux list-windows -t "=$session_name" -F '#{window_id}' 2>/dev/null \
         | grep -qx -- "$origin_id"; then
      tmux select-window -t "$origin_id"
      return
    fi
  fi

  # 2. Fallback: highest-indexed shell window.
  local last_name
  last_name=$(tmux list-windows -t "=$session_name" \
                -F '#{window_index} #{window_name}' 2>/dev/null \
              | sort -n -k1 \
              | awk -v t="$TPM_WINDOW_TOOL" -v e="$TPM_WINDOW_EDITOR" \
                  '$2 != t && $2 != e { name = $2 } END { print name }')

  if [[ -z "$last_name" ]]; then
    # No shell window exists — create one at the end of the session.
    # Omit -n so tmux uses the default shell name; the after-new-window
    # hook (dotfiles) renames it to a unique adjective-noun label so
    # repeated invocations don't produce duplicate window names.
    # -P -F captures the *final* name after the hook has run.
    last_name=$(tmux new-window -t "=$session_name" -c "$project_path" \
                  -P -F '#{window_name}')
  fi
  tmux select-window -t "=$session_name:$last_name"
}

current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null || echo "")

case "$current_window" in
  "$TPM_WINDOW_TOOL")
    # claude → editor (or skip to shell if editor disabled)
    if has_editor "$project_key"; then
      if ! window_exists "$session_name" "$TPM_WINDOW_EDITOR"; then
        # Editor window was closed or never created — recreate it.
        editor_cmd=$(get_editor "$project_key")
        tmux new-window -t "=$session_name" -n "$TPM_WINDOW_EDITOR" -c "$project_path" "$editor_cmd"
      fi
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
    # Save the current window ID so we can return here later.
    if window_exists "$session_name" "$TPM_WINDOW_TOOL"; then
      origin_id=$(tmux display-message -p '#{window_id}' 2>/dev/null || true)
      if [[ -n "$origin_id" ]]; then
        tmux set-option -t "=$session_name:" "@tpm-carousel-origin" "$origin_id"
      fi
      tmux select-window -t "=$session_name:$TPM_WINDOW_TOOL"
    fi
    ;;
esac
