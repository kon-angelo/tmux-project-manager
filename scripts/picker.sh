#!/usr/bin/env bash
# picker.sh — fzf-based project picker with preview and actions.
# Invoked by M-p (or configured key).

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

# --- Detect current project for highlighting ---
current_pane_path=$(tmux display-message -p '#{pane_current_path}')
current_project_key=$(detect_current_project "$current_pane_path")
current_session_name=""
if [[ -n "$current_project_key" ]]; then
  current_session_name=$(get_session_name "$current_project_key")
fi

# --- Build project list ---
# Format: "marker session_name │ description │ status"
# The marker is * for current, + for running, space otherwise.
build_list() {
  local filter="${1:-all}" # "all" or "running"
  while IFS=$'\t' read -r session_name key path desc status; do
    [[ "$filter" == "running" && "$status" != "running" ]] && continue

    local marker=" "
    if [[ "$session_name" == "$current_session_name" ]]; then
      marker="*"
    elif [[ "$status" == "running" ]]; then
      marker="+"
    fi
    printf '%s %-12s │ %-40s │ %s\n' "$marker" "$session_name" "${desc:-(no description)}" "$status"
  done < <(list_projects)
}

# --- State file for filter toggle ---
state_file="/tmp/tpm-picker-state"
filter="all"
[[ -f "$state_file" ]] && filter=$(cat "$state_file")

# --- Write list to temp file ---
list_file="/tmp/tpm-picker-list"
build_list "$filter" > "$list_file"

# If the list is empty, show a message
if [[ ! -s "$list_file" ]]; then
  tmux display-message "No projects found (filter: $filter). Check $TPM_PROJECTS_FILE"
  exit 0
fi

# --- Header showing filter state ---
header="Projects [$filter] │ ctrl-f: toggle filter"

# --- Run fzf in popup ---
# The preview script takes a session name and resolves everything from YAML.
# We extract session name from the line by grabbing the second whitespace-delimited word.
selection=$(tmux display-popup -w 80% -h 70% -E "
  cat '$list_file' | \
  fzf \
    --ansi \
    --header='$header' \
    --pointer='▶' \
    --marker='●' \
    --preview='echo {1..3} | awk \"{print \\\$2}\" | xargs $CURRENT_DIR/preview.sh' \
    --preview-window='right:45%:wrap' \
    --expect='ctrl-r,ctrl-x,ctrl-n,ctrl-e,ctrl-f' \
    --no-sort \
    --reverse \
    2>/dev/null || true
") || true

[[ -z "$selection" ]] && exit 0

# --- Parse fzf output ---
# First line: the key pressed (empty = enter)
# Second line: the selected item
action_key=$(echo "$selection" | head -1)
selected_line=$(echo "$selection" | sed -n '2p')

[[ -z "$selected_line" ]] && exit 0

# Extract session name from the selected line (second word after the marker)
selected_session=$(echo "$selected_line" | awk '{print $2}')

[[ -z "$selected_session" ]] && exit 0

# Resolve to project key
selected_key=$(resolve_project_key "$selected_session")
[[ -z "$selected_key" ]] && exit 0

# --- Dispatch action ---
case "$action_key" in
  "ctrl-f")
    # Toggle filter and re-run
    if [[ "$filter" == "all" ]]; then
      echo "running" > "$state_file"
    else
      echo "all" > "$state_file"
    fi
    # Re-invoke picker
    exec "$CURRENT_DIR/picker.sh"
    ;;
  "ctrl-r")
    # Repair
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      "$CURRENT_DIR/repair.sh" "$selected_session"
    else
      tmux display-message "Session '$selected_session' not running. Launch first."
    fi
    ;;
  "ctrl-x")
    # Kill session
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      tmux kill-session -t "=$selected_session"
      tmux display-message "Killed project session: $selected_session"
    else
      tmux display-message "Session '$selected_session' not running."
    fi
    ;;
  "ctrl-n")
    # New shell window
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      project_path=$(get_path "$selected_key")
      tmux new-window -t "=$selected_session" -n "shell" -c "$project_path"
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;
  "ctrl-e")
    # Ensure editor window
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      if ! tmux list-windows -t "=$selected_session" -F '#{window_name}' | grep -qx "editor"; then
        project_path=$(get_path "$selected_key")
        editor_cmd=$(get_editor "$selected_key")
        tmux new-window -t "=$selected_session" -n "editor" -c "$project_path"
        tmux send-keys -t "=$selected_session:editor" "$editor_cmd" Enter
        tmux display-message "Created editor window in '$selected_session'."
      else
        tmux display-message "Editor window already exists in '$selected_session'."
      fi
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;
  *)
    # Enter (default): switch or launch
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;
esac
