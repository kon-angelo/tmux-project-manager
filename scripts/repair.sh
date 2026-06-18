#!/usr/bin/env bash
# repair.sh — Verify and recreate missing managed windows in a project session.
# Usage: repair.sh [session-name]
#
# Adds windows named "$TPM_WINDOW_TOOL" and "$TPM_WINDOW_EDITOR" if missing.
# Never touches user-created windows. Numeric ordering of windows is not
# enforced — windows are addressed by name throughout the plugin.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

session_name="${1:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"

if [[ -z "$session_name" ]]; then
  tmux display-message "tpm: no session given and no current session"
  exit 1
fi

if ! tmux has-session -t "=$session_name" 2>/dev/null; then
  tmux display-message "tpm: session '$session_name' does not exist"
  exit 1
fi

if ! is_managed_session "$session_name"; then
  tmux display-message "tpm: session '$session_name' is not project-managed"
  exit 1
fi

project_key=$(get_session_project_key "$session_name")
if [[ -z "$project_key" ]]; then
  tmux display-message "tpm: cannot resolve project for session '$session_name'"
  exit 1
fi

project_path=$(get_path "$project_key")
tool_cmd=$(get_tool "$project_key")
editor_cmd=$(get_editor "$project_key")

if [[ ! -d "$project_path" ]]; then
  tmux display-message "tpm: project path missing for '$project_key': $project_path"
  exit 1
fi

repaired=0

# Tool window (always required).
if ! window_exists "$session_name" "$TPM_WINDOW_TOOL"; then
  tmux new-window -t "=$session_name" -n "$TPM_WINDOW_TOOL" -c "$project_path" "$tool_cmd"
  repaired=$((repaired + 1))
fi

# Editor window (only if enabled for this project).
if has_editor "$project_key"; then
  if ! window_exists "$session_name" "$TPM_WINDOW_EDITOR"; then
    tmux new-window -t "=$session_name" -n "$TPM_WINDOW_EDITOR" -c "$project_path" "$editor_cmd"
    repaired=$((repaired + 1))
  fi
fi

# Re-tag in case the session was restored without options (e.g. tmux-resurrect).
tag_session "$session_name" "$project_key"

if (( repaired > 0 )); then
  tmux display-message "tpm: repaired $repaired window(s) in '$session_name'"
else
  tmux display-message "tpm: '$session_name' — all windows present"
fi
