#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# launch.sh — Create a project session with managed windows.
# Usage: launch.sh <project-key>
#
# Behaviour:
#   - If the session already exists and is managed, switch to it.
#   - If a session with the same name exists but isn't managed, refuse.
#   - Otherwise: create a new session with window 0 = tool, window 1 = editor (optional).

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

load_projects_cache

project_key="${1:-}"

if [[ -z "$project_key" ]]; then
  echo "Usage: launch.sh <project-key>" >&2
  exit 1
fi

if ! validate_projects_file; then
  tmux display-message "tpm: invalid projects file (see stderr)"
  exit 1
fi

# Resolve key via aliases too — caller may pass an alias.
resolved=$(resolve_project_key "$project_key")
if [[ -n "$resolved" ]]; then
  project_key="$resolved"
fi

session_name=$(get_session_name "$project_key")
project_path=$(get_path "$project_key")
tool_cmd=$(get_tool "$project_key")
editor_cmd=$(get_editor "$project_key")

if [[ -z "$project_path" ]]; then
  tmux display-message "tpm: no path defined for project '$project_key'"
  exit 1
fi

if [[ ! -d "$project_path" ]]; then
  tmux display-message "tpm: project path does not exist: $project_path"
  exit 1
fi

# --- Session collision handling ---
if tmux has-session -t "=$session_name" 2>/dev/null; then
  if ! is_managed_session "$session_name"; then
    tmux display-message "tpm: session '$session_name' exists and is not managed; refusing"
    exit 1
  fi
  record_lru "$project_key"
  tmux switch-client -t "=$session_name"
  exit 0
fi

# --- Create session ---
# Use the command form (last argument) so the tool runs as the window's pane
# command rather than via send-keys. Avoids races and shell-history pollution.
tmux new-session -d -s "$session_name" -n "$TPM_WINDOW_TOOL" -c "$project_path" "$tool_cmd"

# Editor window (optional)
if has_editor "$project_key"; then
  tmux new-window -t "=$session_name" -n "$TPM_WINDOW_EDITOR" -c "$project_path" "$editor_cmd"
fi

# Tag the session and store its project key.
tag_session "$session_name" "$project_key"

# Record LRU access for sort tracking.
record_lru "$project_key"

# Focus the tool window by name (works regardless of base-index).
tmux select-window -t "=$session_name:$TPM_WINDOW_TOOL"

# Switch the current client to the new session.
tmux switch-client -t "=$session_name"
