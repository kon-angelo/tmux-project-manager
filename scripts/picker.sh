#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
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

# Eager-load the project + session caches in the parent shell so that the
# many `$(getter ...)` calls inside the build_lines loop don't each spawn a
# fresh yq process (subshells inherit our state but cannot mutate it back,
# so a lazy loader would re-run on every subshell).
load_projects_cache
load_session_cache

# --- State (user-scoped) ---
state_file="${TPM_STATE_PREFIX}-picker-state"
list_file="${TPM_STATE_PREFIX}-picker-list"
result_file="${TPM_STATE_PREFIX}-picker-result"

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
# Each row has FIVE tab-separated fields (after sort prefix is stripped):
#   1. session_name   — used for extraction after fzf returns
#   2. project_key    — passed through to fzf for searching
#   3. searchable     — extra metadata bag (description, path, personas, aliases)
#   4. display        — the visible content (marker + alias + key) shown to the user
#
# Layout strategy:
#   The visible content is emitted FIRST so the alias/key are always at the
#   left of the row regardless of whether the terminal honours SGR 8.
#   The searchable bag is appended AFTER the visible block, dimmed (SGR 2 +
#   bright-black foreground). fzf with --ansi strips the codes for matching,
#   so the user can search by description/persona/path, but the content is
#   visually de-emphasised and pushed to the right.
build_lines() {
  local f="${1:-all}"
  local DIM=$'\033[2;38;5;240m'   # SGR 2 (dim) + 256-color dark gray
  local RESET=$'\033[0m'

  while IFS=$'\t' read -r session_name key path desc status; do
    [[ "$f" == "running" && "$status" != "running" ]] && continue

    local marker="·" sort_key="2"
    if [[ "$session_name" == "$current_session_name" ]]; then
      marker="*"
      sort_key="0"
    elif [[ "$status" == "running" ]]; then
      marker="+"
      sort_key="1"
    fi

    local key_display=""
    if [[ "$key" != "$session_name" ]]; then
      key_display="($key)"
    fi

    local searchable visible display
    searchable=$(get_searchable_text "$key")
    # Pad visible block to a fixed column width so the dimmed metadata
    # always starts at the same horizontal position.
    printf -v visible '%s %-12s %-44s' "$marker" "$session_name" "$key_display"
    display="${visible}${DIM}${searchable}${RESET}"

    # sort_key prefix is stripped after sort.
    printf '%s\t%s\t%s\t%s\t%s\n' "$sort_key" "$session_name" "$key" "$searchable" "$display"
  done < <(list_projects)
}

build_lines "$filter" | sort -k1,1 -s | cut -f2- > "$list_file"

if [[ ! -s "$list_file" ]]; then
  tmux display-message "tpm: no projects found (filter: $filter) — check $TPM_PROJECTS_FILE"
  exit 0
fi

header="Projects [$filter]   enter:switch  ^r:repair  ^x:kill  ^n:shell  ^e:editor  ^f:filter"

# --- Run fzf inside a tmux popup and capture the result via a file ---
# We can't reliably capture fzf's stdout through `$(tmux display-popup -E ...)`,
# so the popup writes its result to $result_file and we read it after the
# popup closes.
#
# --height=100% is mandatory: many users set FZF_DEFAULT_OPTS='--height 40%'
# globally, which would shrink fzf to a sliver of the popup. Forcing 100%
# ensures fzf fills the popup before the preview-window split is applied.
rm -f "$result_file"

tmux display-popup -w 90% -h 80% -E "
  cat '$list_file' | \
  fzf \
    --ansi \
    --height=100% \
    --header='$header' \
    --delimiter=\$'\t' \
    --with-nth=4 \
    --pointer='▶' \
    --marker='●' \
    --preview='$CURRENT_DIR/preview.sh {1}' \
    --preview-window='down:50%:wrap' \
    --expect='ctrl-r,ctrl-x,ctrl-n,ctrl-e,ctrl-f' \
    --no-sort \
    --reverse \
    > '$result_file'
" 2>/dev/null || true

[[ ! -s "$result_file" ]] && exit 0
selection=$(<"$result_file")
rm -f "$result_file"

# --- Parse fzf output ---
# Line 1: the action key (empty for plain Enter)
# Line 2: the selected row (TAB-separated: session_name<TAB>display)
action_key=$(printf '%s\n' "$selection" | sed -n '1p')
selected_line=$(printf '%s\n' "$selection" | sed -n '2p')
[[ -z "$selected_line" ]] && exit 0

selected_session=$(printf '%s' "$selected_line" | cut -f1)
[[ -z "$selected_session" ]] && exit 0

selected_key=$(resolve_project_key "$selected_session")
if [[ -z "$selected_key" ]]; then
  tmux display-message "tpm: cannot resolve project for '$selected_session'"
  exit 0
fi

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
