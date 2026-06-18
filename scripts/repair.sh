#!/usr/bin/env bash
# repair.sh — Verify and recreate missing managed windows in a project session.
# Usage: repair.sh [session-name]
# If no session name given, uses the current session.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

session_name="${1:-$(tmux display-message -p '#{session_name}')}"

# Verify this is a managed session
if ! is_managed_session "$session_name"; then
  tmux display-message "Session '$session_name' is not a project-managed session."
  exit 1
fi

# Get project key from session option
project_key=$(tmux show-option -t "=$session_name" -qv "@tpm-project-key" 2>/dev/null)
if [[ -z "$project_key" ]]; then
  tmux display-message "No project key found for session '$session_name'."
  exit 1
fi

project_path=$(get_path "$project_key")
tool_cmd=$(get_tool "$project_key")
editor_cmd=$(get_editor "$project_key")

repaired=0

# --- Check window 0: claude ---
# Look for a window named "claude"
if ! tmux list-windows -t "=$session_name" -F '#{window_name}' | grep -qx "claude"; then
  # Window is missing — recreate at index 0 if available, otherwise at next slot
  # Try to insert at index 0
  if ! tmux list-windows -t "=$session_name" -F '#{window_index}' | grep -qx "0"; then
    tmux new-window -t "=$session_name:0" -n "claude" -c "$project_path"
  else
    # Index 0 is occupied by something else — create claude and swap
    tmux new-window -t "=$session_name" -n "claude" -c "$project_path"
    # Move it to the front
    claude_idx=$(tmux list-windows -t "=$session_name" -F '#{window_index} #{window_name}' | awk '$2=="claude"{print $1}')
    if [[ -n "$claude_idx" && "$claude_idx" != "0" ]]; then
      tmux swap-window -t "=$session_name:0" -s "=$session_name:$claude_idx"
    fi
  fi
  tmux send-keys -t "=$session_name:claude" "$tool_cmd" Enter
  repaired=$((repaired + 1))
fi

# --- Check window 1: editor (if enabled) ---
if has_editor "$project_key"; then
  if ! tmux list-windows -t "=$session_name" -F '#{window_name}' | grep -qx "editor"; then
    if ! tmux list-windows -t "=$session_name" -F '#{window_index}' | grep -qx "1"; then
      tmux new-window -t "=$session_name:1" -n "editor" -c "$project_path"
    else
      tmux new-window -t "=$session_name" -n "editor" -c "$project_path"
      editor_idx=$(tmux list-windows -t "=$session_name" -F '#{window_index} #{window_name}' | awk '$2=="editor"{print $1}')
      if [[ -n "$editor_idx" && "$editor_idx" != "1" ]]; then
        tmux swap-window -t "=$session_name:1" -s "=$session_name:$editor_idx"
      fi
    fi
    tmux send-keys -t "=$session_name:editor" "$editor_cmd" Enter
    repaired=$((repaired + 1))
  fi
fi

if (( repaired > 0 )); then
  tmux display-message "Repaired $repaired window(s) in project '$session_name'."
else
  tmux display-message "Project '$session_name' — all windows intact."
fi
