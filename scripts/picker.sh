#!/usr/bin/env bash
# picker.sh — fzf-based project picker with preview and action keybinds.
# Invoked by the configured key (default M-p, no prefix).

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

if ! validate_projects_file; then
  tmux display-message "tpm: invalid projects file (see stderr)"
  exit 1
fi

# --- State (user-scoped) ---
state_file="${TPM_STATE_PREFIX}-picker-state"
list_file="${TPM_STATE_PREFIX}-picker-list"

filter="all"
[[ -f "$state_file" ]] && filter=$(<"$state_file")

# --- Detect current project for highlighting/sorting ---
current_pane_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)
current_project_key=$(detect_current_project "$current_pane_path")
current_session_name=""
if [[ -n "$current_project_key" ]]; then
  current_session_name=$(get_session_name "$current_project_key")
fi

# --- Build the list ---
# Format on each line: "<marker> <session_name> │ <description> │ <status>"
# Marker: '*' = current project, '+' = running, ' ' = idle.
# Lines are pre-sorted: current project first (if any), then running, then rest.
build_lines() {
  local f="${1:-all}"
  while IFS=$'\t' read -r session_name key path desc status; do
    [[ "$f" == "running" && "$status" != "running" ]] && continue

    local marker=" " sort_key="2"
    if [[ "$session_name" == "$current_session_name" ]]; then
      marker="*"
      sort_key="0"
    elif [[ "$status" == "running" ]]; then
      marker="+"
      sort_key="1"
    fi
    # Prepend a sort prefix that we strip after sort.
    printf '%s\t%s %-12s │ %-40s │ %s\n' \
      "$sort_key" "$marker" "$session_name" "${desc:-(no description)}" "$status"
  done < <(list_projects)
}

build_lines "$filter" | sort -k1,1 -s | cut -f2- > "$list_file"

if [[ ! -s "$list_file" ]]; then
  tmux display-message "tpm: no projects found (filter: $filter) — check $TPM_PROJECTS_FILE"
  exit 0
fi

header="Projects [$filter] │ enter:switch  ^r:repair  ^x:kill  ^n:shell  ^e:editor  ^f:filter"

# --- Run fzf in a tmux popup ---
# fzf field index {2} is the second whitespace-separated token, which is the
# session name (after the marker character at position 1).
selection=$(tmux display-popup -w 80% -h 70% -E "
  cat '$list_file' | \
  fzf \
    --ansi \
    --header='$header' \
    --pointer='▶' \
    --marker='●' \
    --preview='$CURRENT_DIR/preview.sh {2}' \
    --preview-window='right:50%:wrap' \
    --expect='ctrl-r,ctrl-x,ctrl-n,ctrl-e,ctrl-f' \
    --no-sort \
    --reverse
") || true

[[ -z "$selection" ]] && exit 0

action_key=$(printf '%s\n' "$selection" | sed -n '1p')
selected_line=$(printf '%s\n' "$selection" | sed -n '2p')
[[ -z "$selected_line" ]] && exit 0

# Second whitespace token is the session name.
selected_session=$(printf '%s' "$selected_line" | awk '{print $2}')
[[ -z "$selected_session" ]] && exit 0

selected_key=$(resolve_project_key "$selected_session")
[[ -z "$selected_key" ]] && exit 0

# --- Dispatch ---
case "$action_key" in
  ctrl-f)
    if [[ "$filter" == "all" ]]; then
      printf 'running' > "$state_file"
    else
      printf 'all' > "$state_file"
    fi
    exec "$CURRENT_DIR/picker.sh"
    ;;

  ctrl-r)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      "$CURRENT_DIR/repair.sh" "$selected_session"
    else
      tmux display-message "tpm: '$selected_session' is not running — launch first"
    fi
    ;;

  ctrl-x)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      tmux kill-session -t "=$selected_session"
      tmux display-message "tpm: killed '$selected_session'"
    else
      tmux display-message "tpm: '$selected_session' is not running"
    fi
    ;;

  ctrl-n)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      project_path=$(get_path "$selected_key")
      tmux new-window -t "=$selected_session" -n "shell" -c "$project_path"
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;

  ctrl-e)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      if ! window_exists "$selected_session" "$TPM_WINDOW_EDITOR"; then
        project_path=$(get_path "$selected_key")
        editor_cmd=$(get_editor "$selected_key")
        tmux new-window -t "=$selected_session" -n "$TPM_WINDOW_EDITOR" \
          -c "$project_path" "$editor_cmd"
        tmux display-message "tpm: created editor window in '$selected_session'"
      else
        tmux display-message "tpm: '$selected_session' already has an editor window"
      fi
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;

  *)
    # Default (Enter): switch or launch.
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;
esac
