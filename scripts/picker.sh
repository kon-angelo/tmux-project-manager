#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# picker.sh — fzf-based project picker with preview and action keybinds.
# Invoked by whatever key the user binds to scripts/picker.sh (see README →
# Recommended bindings).
#
# Supports two search modes (toggled with alt-a inside fzf):
#   fuzzy  — default fzf fuzzy matching
#   strict — exact substring matching only (alias-oriented)

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
sort_file="${TPM_STATE_PREFIX}-picker-sort"
search_file="${TPM_STATE_PREFIX}-picker-search"
list_file="${TPM_STATE_PREFIX}-picker-list"
result_file="${TPM_STATE_PREFIX}-picker-result"

filter="all"
[[ -f "$state_file" ]] && filter=$(<"$state_file")

sort_mode="alpha"
[[ -f "$sort_file" ]] && sort_mode=$(<"$sort_file")

search_mode="fuzzy"
[[ -f "$search_file" ]] && search_mode=$(<"$search_file")

# --- Detect current project for highlighting/sorting ---
# Only mark a project as "current" if we're actually inside a managed session.
# Detection order:
#   1. @tpm-project-key session option (set at launch, survives path case mismatches)
#   2. Path-based longest-prefix matching (for nested project disambiguation)
current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
current_session_name=""
if is_managed_session "$current_session"; then
  current_project_key=$(get_session_project_key "$current_session" 2>/dev/null || true)
  if [[ -z "$current_project_key" ]]; then
    current_pane_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)
    current_project_key=$(detect_current_project "$current_pane_path")
  fi
  if [[ -n "$current_project_key" ]]; then
    current_session_name=$(get_session_name "$current_project_key")
  fi
fi

# --- Build the list ---
# Each row has FIVE tab-separated fields (after sort prefix is stripped):
#   1. session_name   — used for extraction after fzf returns
#   2. project_key    — passed through to fzf for searching
#   3. searchable     — extra metadata bag (description, path, personas, aliases)
#   4. display        — the visible content (agent badge + marker + alias + key)
#
# Layout strategy:
#   The visible content is emitted FIRST so the alias/key are always at the
#   left of the row regardless of whether the terminal honours SGR 8.
#   The searchable bag is appended AFTER the visible block, dimmed (SGR 2 +
#   bright-black foreground). fzf with --ansi strips the codes for matching,
#   so the user can search by description/persona/path, but the content is
#   visually de-emphasised and pushed to the right.
#
# Agent status badge (leftmost, 2 chars):
#   `! ` yellow   needs-input   agent blocked on approval
#   `x ` red      error         agent hit an error
#   `● ` green    done          agent finished, unread
#   `~ ` dim      working       agent is busy
#   `  ` (blank)  ready / empty no attention needed
#
# The badge is only rendered when the aggregated status option is set on the
# session (see get_agent_status in utils.sh). Sort order is NOT changed;
# attention-needing projects surface visually, not positionally.
build_lines() {
  local f="${1:-all}" sm="${2:-alpha}"
  local DIM=$'\033[2;38;5;240m'   # SGR 2 (dim) + 256-color dark gray
  local CURRENT=$'\033[38;5;220m'   # yellow — current project highlight
  local RESET=$'\033[0m'

  # Nord palette for the agent badge — kept inline so the picker has no
  # dependency on external colour definitions.
  local BADGE_NEEDS=$'\033[1;38;5;179m'   # nord13 yellow, bold
  local BADGE_ERROR=$'\033[1;38;5;167m'   # nord11 red, bold
  local BADGE_DONE=$'\033[38;5;108m'      # nord14 green
  local BADGE_WORKING=$'\033[2;38;5;244m' # dim grey

  while IFS=$'\t' read -r session_name key path desc status agent_status; do
    [[ "$f" == "running" && "$status" != "running" ]] && continue

    local marker="·" sort_group="2"
    if [[ "$session_name" == "$current_session_name" ]]; then
      marker="*"
      sort_group="0"
    elif [[ "$status" == "running" ]]; then
      marker="+"
      sort_group="1"
    fi

    # Agent status badge. Always 2 visual columns wide, so all rows align.
    local badge="  "
    case "$agent_status" in
      needs-input) badge="${BADGE_NEEDS}! ${RESET}" ;;
      error)       badge="${BADGE_ERROR}x ${RESET}" ;;
      done)        badge="${BADGE_DONE}● ${RESET}" ;;
      working)     badge="${BADGE_WORKING}~ ${RESET}" ;;
    esac

    # Secondary sort key depends on mode:
    #   alpha — session name (lexicographic ascending)
    #   lru   — inverse timestamp (numeric descending, padded for sort)
    local sort_secondary
    if [[ "$sm" == "lru" ]]; then
      local ts
      ts=$(get_lru_timestamp "$key")
      # Invert: subtract from a large number so higher timestamps sort first.
      # 10-digit zero-padded for stable numeric sort.
      printf -v sort_secondary '%010d' $(( 9999999999 - ts ))
    else
      sort_secondary="$session_name"
    fi

    local key_display=""
    if [[ "$key" != "$session_name" ]]; then
      key_display="($key)"
    fi

    local searchable body display
    searchable=$(get_searchable_text "$key")
    # Pad body block to a fixed column width so the dimmed metadata always
    # starts at the same horizontal position. The badge is prepended as-is;
    # its ANSI codes don't affect printf's %-N padding of subsequent fields.
    printf -v body '%s %-12s %-44s' "$marker" "$session_name" "$key_display"
    if [[ "$session_name" == "$current_session_name" ]]; then
      display="${badge}${CURRENT}${body}${searchable}${RESET}"
    else
      display="${badge}${body}${DIM}${searchable}${RESET}"
    fi

    # Fields: sort_group, sort_secondary, session_name, key, searchable, display
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sort_group" "$sort_secondary" "$session_name" "$key" "$searchable" "$display"
  done < <(list_projects)
}

build_lines "$filter" "$sort_mode" | sort -t$'\t' -k1,1 -k2,2 -s | cut -f3- > "$list_file"

# If the user has the "running" filter active but nothing is actually running,
# transparently fall back to "all" so the picker remains useful instead of
# bailing out with a "no projects found" message. The persisted filter state
# is left untouched: as soon as a project is running, the filter snaps back.
if [[ ! -s "$list_file" && "$filter" == "running" ]]; then
  filter="all"
  build_lines "$filter" "$sort_mode" | sort -t$'\t' -k1,1 -k2,2 -s | cut -f3- > "$list_file"
fi

if [[ ! -s "$list_file" ]]; then
  tmux display-message "tpm: no projects found (filter: $filter) — check $TPM_PROJECTS_FILE"
  exit 0
fi

header="Projects [$filter|$sort_mode|$search_mode]  enter:switch  alt-1..9:quick  M-a:search  M-s:sort  M-r:repair  M-x:kill  M-n:shell  M-e:editor  M-u:filter"

# --- Run fzf inside a tmux popup and capture the result via a file ---
# We can't reliably capture fzf's stdout through `$(tmux display-popup -E ...)`,
# so the popup writes its result to $result_file and we read it after the
# popup closes.
#
# --height=100% is mandatory: many users set FZF_DEFAULT_OPTS='--height 40%'
# globally, which would shrink fzf to a sliver of the popup. Forcing 100%
# ensures fzf fills the popup before the preview-window split is applied.
#
# alt-1..9 quick-pick: each binding moves the cursor to the Nth visible item
# (after current filter/sort) and immediately accepts. Same effect as Enter
# on that row, so the wrapper script's default action handles it.
rm -f "$result_file"

# In strict mode, fzf uses exact matching restricted to alias/key fields only
# (fields 1=session_name, 2=key). In fuzzy mode, all fields are searched.
_fzf_search_flag=""
if [[ "$search_mode" == "strict" ]]; then
  _fzf_search_flag="--exact --nth=1,2"
fi

# If the current project is at the top of the list, start the cursor on the
# second item so Enter immediately switches elsewhere — but the current project
# remains reachable by navigating up.
_fzf_start_pos=""
if [[ -n "$current_session_name" ]]; then
  first_entry=$(head -1 "$list_file" | cut -f1)
  if [[ "$first_entry" == "$current_session_name" ]]; then
    _fzf_start_pos="--bind='start:wait+pos(2)'"
  fi
fi

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
    --color='pointer:green,fg+:green,bg+:-1' \
    --preview='$CURRENT_DIR/preview.sh {1}' \
    --preview-window='down:50%:wrap' \
    --expect='alt-a,alt-r,alt-x,alt-n,alt-e,alt-u,alt-s' \
    --bind='alt-1:pos(1)+accept' \
    --bind='alt-2:pos(2)+accept' \
    --bind='alt-3:pos(3)+accept' \
    --bind='alt-4:pos(4)+accept' \
    --bind='alt-5:pos(5)+accept' \
    --bind='alt-6:pos(6)+accept' \
    --bind='alt-7:pos(7)+accept' \
    --bind='alt-8:pos(8)+accept' \
    --bind='alt-9:pos(9)+accept' \
    --no-sort \
    --reverse \
    $_fzf_search_flag \
    $_fzf_start_pos \
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
  alt-a)
    if [[ "$search_mode" == "fuzzy" ]]; then
      printf 'strict' > "$search_file"
    else
      printf 'fuzzy' > "$search_file"
    fi
    exec "$CURRENT_DIR/picker.sh"
    ;;

  alt-s)
    if [[ "$sort_mode" == "alpha" ]]; then
      printf 'lru' > "$sort_file"
    else
      printf 'alpha' > "$sort_file"
    fi
    exec "$CURRENT_DIR/picker.sh"
    ;;

  alt-u)
    if [[ "$filter" == "all" ]]; then
      printf 'running' > "$state_file"
    else
      printf 'all' > "$state_file"
    fi
    exec "$CURRENT_DIR/picker.sh"
    ;;

  alt-r)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      "$CURRENT_DIR/repair.sh" "$selected_session"
    else
      tmux display-message "tpm: '$selected_session' is not running — launch first"
    fi
    ;;

  alt-x)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      # Guard: if killing the active session, switch away first to avoid
      # stranding the user with no attached session.
      if [[ "$selected_session" == "$current_session" ]]; then
        tmux switch-client -n
      fi
      tmux kill-session -t "=$selected_session"
      tmux display-message "tpm: killed '$selected_session'"
    else
      tmux display-message "tpm: '$selected_session' is not running"
    fi
    ;;

  alt-n)
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      project_path=$(get_path "$selected_key")
      tmux new-window -t "=$selected_session" -n "shell" -c "$project_path"
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;

  alt-e)
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
    # Default (Enter): switch or launch. Record LRU timestamp.
    record_lru "$selected_key"
    if tmux has-session -t "=$selected_session" 2>/dev/null; then
      tmux switch-client -t "=$selected_session"
    else
      "$CURRENT_DIR/launch.sh" "$selected_key"
    fi
    ;;
esac
