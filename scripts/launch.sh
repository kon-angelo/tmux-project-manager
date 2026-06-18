#!/usr/bin/env bash
# launch.sh — Create a project session with managed windows.
# Usage: launch.sh <project-key>

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

project_key="$1"

if [[ -z "$project_key" ]]; then
  echo "Usage: launch.sh <project-key>" >&2
  exit 1
fi

session_name=$(get_session_name "$project_key")
project_path=$(get_path "$project_key")
tool_cmd=$(get_tool "$project_key")
editor_cmd=$(get_editor "$project_key")

# Validate path exists
if [[ ! -d "$project_path" ]]; then
  tmux display-message "Project path does not exist: $project_path"
  exit 1
fi

# Check for session name collision with non-managed session
if tmux has-session -t "=$session_name" 2>/dev/null; then
  if ! is_managed_session "$session_name"; then
    tmux display-message "Session '$session_name' exists but is not project-managed. Skipping."
    exit 1
  fi
  # Session already exists and is managed — just switch to it
  tmux switch-client -t "=$session_name"
  exit 0
fi

# --- Create session ---
# Window 0: claude (tool)
tmux new-session -d -s "$session_name" -n "claude" -c "$project_path"
tmux send-keys -t "=$session_name:claude" "$tool_cmd" Enter

# Window 1: editor (if enabled)
if has_editor "$project_key"; then
  tmux new-window -t "=$session_name" -n "editor" -c "$project_path"
  tmux send-keys -t "=$session_name:editor" "$editor_cmd" Enter
fi

# Tag the session as managed
tag_session "$session_name"

# Store the project key for reference
tmux set-option -t "=$session_name" "@tpm-project-key" "$project_key" 2>/dev/null

# Select window 0 (claude) as the default view
tmux select-window -t "=$session_name:0"

# Switch to the new session
tmux switch-client -t "=$session_name"
