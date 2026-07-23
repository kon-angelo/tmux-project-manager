#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# utils.sh — Shared utilities for tmux-project-manager
# YAML parsing, session tagging, current-project detection.
#
# Performance: yq has a ~15ms per-invocation startup cost. Calling it once
# per field per project (path, description, aliases, etc.) added up to
# ~1.5s for the picker. We now load the entire projects file via a SINGLE
# yq invocation that emits TSV, then populate bash associative arrays.
# Subsequent getter calls are hash lookups — sub-millisecond.

# --- Environment ---
TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$(tmux show-environment -g TPM_PROJECTS_FILE 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-$(tmux show-environment -g TPM_DEFAULT_TOOL 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-$(tmux show-environment -g TPM_DEFAULT_EDITOR 2>/dev/null | cut -d= -f2-)}"
TPM_SCRIPTS_DIR="${TPM_SCRIPTS_DIR:-$(tmux show-environment -g TPM_SCRIPTS_DIR 2>/dev/null | cut -d= -f2-)}"

TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$HOME/.config/projects/projects.yaml}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-opencode}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-nvim}"

# --- Constants ---
TPM_TAG="@tpm-managed"
TPM_PROJECT_KEY_OPT="@tpm-project-key"
TPM_WINDOW_TOOL="claude"
TPM_WINDOW_EDITOR="editor"
TPM_TMP_DIR="${TMPDIR:-/tmp}"
TPM_STATE_PREFIX="${TPM_TMP_DIR%/}/tpm-${USER:-default}"

# --- Agent status ---
# Per-source option namespace: @tpm-agent-status-<source>-<id> = <state>
# Aggregated read-only cache: @tpm-agent-status = <highest-priority state>
#
# Clients (opencode plugin, Claude Code hook) write per-source options and
# call the aggregator. The picker reads only the aggregated option.
TPM_AGENT_STATUS_OPT="@tpm-agent-status"
TPM_AGENT_STATUS_PREFIX="@tpm-agent-status-"

# --- Cache (associative arrays, populated by load_projects_cache) ---
declare -A _TPM_PATH        # key -> filesystem path
declare -A _TPM_SESSION     # key -> session name (first alias or key)
declare -A _TPM_DESC        # key -> description
declare -A _TPM_TOOL        # key -> tool command (default-resolved)
declare -A _TPM_EDITOR      # key -> editor command (default-resolved)
declare -A _TPM_HAS_EDITOR  # key -> "1" or "0"
declare -A _TPM_ALIASES     # key -> comma-separated alias list
declare -A _TPM_PERSONAS    # key -> comma-separated persona list
declare -A _TPM_ALIAS_TO_KEY # alias-or-key -> canonical key
declare -a _TPM_KEYS        # ordered list of keys (file order)

# Cached session-set (built lazily).
declare -a _TPM_SESSION_LIST
_TPM_SESSION_LIST_LOADED=0

_TPM_CACHE_LOADED=0

# Load all project data with a single yq call. Idempotent; a second call is
# a no-op unless _TPM_CACHE_LOADED is reset.
load_projects_cache() {
  (( _TPM_CACHE_LOADED == 1 )) && return 0
  [[ ! -f "$TPM_PROJECTS_FILE" ]] && return 1

  local key alias_first path desc tool editor nvim aliases personas
  while IFS=$'\x1f' read -r key alias_first path desc tool editor nvim aliases personas; do
    [[ -z "$key" ]] && continue
    _TPM_KEYS+=("$key")
    path="${path/#\~/$HOME}"
    _TPM_PATH["$key"]="${path%/}"
    _TPM_SESSION["$key"]="${alias_first:-$key}"
    _TPM_DESC["$key"]="$desc"
    _TPM_TOOL["$key"]="${tool:-$TPM_DEFAULT_TOOL}"
    _TPM_EDITOR["$key"]="${editor:-$TPM_DEFAULT_EDITOR}"
    if [[ "$nvim" == "false" ]]; then
      _TPM_HAS_EDITOR["$key"]="0"
    else
      _TPM_HAS_EDITOR["$key"]="1"
    fi
    _TPM_ALIASES["$key"]="$aliases"
    _TPM_PERSONAS["$key"]="$personas"

    # Build the alias→key reverse index. The canonical key itself is
    # registered too (so resolve_project_key can find it via the same map).
    _TPM_ALIAS_TO_KEY["$key"]="$key"
    if [[ -n "$aliases" ]]; then
      local IFS_BACKUP="$IFS"
      IFS=','
      local a
      for a in $aliases; do
        [[ -n "$a" ]] && _TPM_ALIAS_TO_KEY["$a"]="$key"
      done
      IFS="$IFS_BACKUP"
    fi
  done < <(
    # Pipe yq's tab-separated output through `tr` to swap tabs for ASCII Unit
    # Separator (\x1f). bash's `read` with IFS set to a whitespace character
    # collapses consecutive separators — losing empty fields. \x1f is
    # non-whitespace, so empty fields between two delimiters are preserved.
    yq -r '
      to_entries | .[] | select(.key | test("^[^_]")) |
      [
        .key,
        (.value.aliases[0] // .key),
        (.value.path // ""),
        (.value.description // ""),
        (.value.tool // ""),
        (.value.editor // ""),
        (.value.nvim // true | tostring),
        ((.value.aliases // []) | join(",")),
        ((.value.personas // []) | join(","))
      ] | @tsv
    ' "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null \
      | tr '\t' $'\x1f'
  )

  _TPM_CACHE_LOADED=1
  return 0
}

# Force-reload (callable by tests / clients that mutate the file).
reload_projects_cache() {
  _TPM_CACHE_LOADED=0
  _TPM_KEYS=()
  _TPM_PATH=()
  _TPM_SESSION=()
  _TPM_DESC=()
  _TPM_TOOL=()
  _TPM_EDITOR=()
  _TPM_HAS_EDITOR=()
  _TPM_ALIASES=()
  _TPM_PERSONAS=()
  _TPM_ALIAS_TO_KEY=()
  load_projects_cache
}

# --- Validation ---

validate_projects_file() {
  if [[ ! -f "$TPM_PROJECTS_FILE" ]]; then
    echo "tpm: projects file not found: $TPM_PROJECTS_FILE" >&2
    return 1
  fi
  if ! yq -e 'type == "!!map"' "$TPM_PROJECTS_FILE" < /dev/null &>/dev/null; then
    echo "tpm: projects file is not a valid YAML mapping: $TPM_PROJECTS_FILE" >&2
    return 1
  fi
  return 0
}

# --- Cached session set ---

# Build the session-name set with a single tmux list-sessions call.
load_session_cache() {
  (( _TPM_SESSION_LIST_LOADED == 1 )) && return 0
  mapfile -t _TPM_SESSION_LIST < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  _TPM_SESSION_LIST_LOADED=1
}

session_running() {
  local target="$1" s
  load_session_cache
  for s in "${_TPM_SESSION_LIST[@]}"; do
    [[ "$s" == "$target" ]] && return 0
  done
  return 1
}

# Reset session cache (callable after launching/killing sessions).
invalidate_session_cache() {
  _TPM_SESSION_LIST_LOADED=0
  _TPM_SESSION_LIST=()
}

# --- Getters (all hash lookups) ---

list_project_keys() {
  load_projects_cache
  printf '%s\n' "${_TPM_KEYS[@]}"
}

get_path()             { load_projects_cache; printf '%s\n' "${_TPM_PATH[$1]:-}"; }
get_session_name()     { load_projects_cache; printf '%s\n' "${_TPM_SESSION[$1]:-$1}"; }
get_description()      { load_projects_cache; printf '%s\n' "${_TPM_DESC[$1]:-}"; }
get_tool()             { load_projects_cache; printf '%s\n' "${_TPM_TOOL[$1]:-$TPM_DEFAULT_TOOL}"; }
get_editor()           { load_projects_cache; printf '%s\n' "${_TPM_EDITOR[$1]:-$TPM_DEFAULT_EDITOR}"; }

has_editor() {
  load_projects_cache
  [[ "${_TPM_HAS_EDITOR[$1]:-1}" == "1" ]]
}

# Get a generic field. Kept for backward compatibility but rarely needed now
# that we cache the common fields.
get_field() {
  local key="$1" field="$2"
  case "$field" in
    path)        get_path "$key" ;;
    description) get_description "$key" ;;
    tool)        get_tool "$key" ;;
    editor)      get_editor "$key" ;;
    nvim)        load_projects_cache; [[ "${_TPM_HAS_EDITOR[$key]:-1}" == "1" ]] && echo "true" || echo "false" ;;
    *) yq -r ".[\"$key\"].$field // \"\"" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null ;;
  esac
}

# Searchable bag for the picker (description + path + personas + aliases).
get_searchable_text() {
  load_projects_cache
  local key="$1"
  local desc="${_TPM_DESC[$key]:-}"
  local path="${_TPM_PATH[$key]:-}"
  local personas="${_TPM_PERSONAS[$key]//,/ }"
  local aliases="${_TPM_ALIASES[$key]//,/ }"
  printf '%s %s %s %s' "$desc" "$path" "$personas" "$aliases" | tr '\t\n' '  '
}

# --- Project list (for picker) ---

# TAB-separated lines: session_name, key, path, description, status (running|stopped), agent_status
# agent_status is empty for stopped sessions and for running sessions with
# no @tpm-agent-status-* options set. See `get_agent_status` for aggregation.
list_projects() {
  load_projects_cache
  load_session_cache
  local key session_name running agent_status
  for key in "${_TPM_KEYS[@]}"; do
    session_name="${_TPM_SESSION[$key]:-$key}"
    if session_running "$session_name"; then
      running="running"
      agent_status=$(get_agent_status "$session_name")
    else
      running="stopped"
      agent_status=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$session_name" "$key" "${_TPM_PATH[$key]:-}" "${_TPM_DESC[$key]:-}" "$running" "$agent_status"
  done
}

# --- Current-project detection ---

detect_current_project() {
  local cwd="${1:-$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)}"
  [[ -z "$cwd" ]] && return 0

  load_projects_cache
  local best_key="" best_len=0
  local key project_path plen

  for key in "${_TPM_KEYS[@]}"; do
    project_path="${_TPM_PATH[$key]:-}"
    [[ -z "$project_path" ]] && continue
    if [[ "$cwd" == "$project_path" || "$cwd" == "$project_path"/* ]]; then
      plen=${#project_path}
      if (( plen > best_len )); then
        best_len=$plen
        best_key="$key"
      fi
    fi
  done

  printf '%s\n' "$best_key"
}

detect_current_session_name() {
  local key
  key=$(detect_current_project "$@")
  if [[ -n "$key" ]]; then
    get_session_name "$key"
  fi
}

# --- Session tagging ---

tag_session() {
  local session_name="$1" project_key="${2:-}"
  tmux set-option -t "=$session_name:" "$TPM_TAG" "1" 2>/dev/null
  if [[ -n "$project_key" ]]; then
    tmux set-option -t "=$session_name:" "$TPM_PROJECT_KEY_OPT" "$project_key" 2>/dev/null
  fi
}

is_managed_session() {
  local session_name="$1" val key expected_session
  val=$(tmux show-option -t "=$session_name:" -qv "$TPM_TAG" 2>/dev/null)
  if [[ "$val" == "1" ]]; then
    return 0
  fi
  key=$(resolve_project_key "$session_name")
  if [[ -n "$key" ]]; then
    expected_session=$(get_session_name "$key")
    if [[ "$expected_session" == "$session_name" ]]; then
      tag_session "$session_name" "$key"
      return 0
    fi
  fi
  return 1
}

get_session_project_key() {
  local session_name="$1" key
  key=$(tmux show-option -t "=$session_name:" -qv "$TPM_PROJECT_KEY_OPT" 2>/dev/null)
  if [[ -n "$key" ]]; then
    printf '%s\n' "$key"
    return 0
  fi
  key=$(resolve_project_key "$session_name")
  if [[ -n "$key" ]]; then
    tmux set-option -t "=$session_name:" "$TPM_PROJECT_KEY_OPT" "$key" 2>/dev/null
    printf '%s\n' "$key"
    return 0
  fi
  return 1
}

list_managed_sessions() {
  load_session_cache
  local s
  for s in "${_TPM_SESSION_LIST[@]}"; do
    [[ -z "$s" ]] && continue
    if is_managed_session "$s"; then
      printf '%s\n' "$s"
    fi
  done
}

# --- Key-to-project resolution ---

# Resolve an alias or direct key to the canonical project key. Empty if no match.
resolve_project_key() {
  load_projects_cache
  local query="$1"
  [[ -z "$query" ]] && return 0
  printf '%s\n' "${_TPM_ALIAS_TO_KEY[$query]:-}"
}

# Resolve a query to a project key via exact match first, then unique prefix
# match against all known aliases and keys. Returns the canonical key if
# exactly one candidate matches; empty string otherwise.
resolve_project_key_fuzzy() {
  load_projects_cache
  local query="$1"
  [[ -z "$query" ]] && return 0

  # 1. Exact match (fast path via the alias→key map)
  local exact="${_TPM_ALIAS_TO_KEY[$query]:-}"
  if [[ -n "$exact" ]]; then
    printf '%s\n' "$exact"
    return 0
  fi

  # 2. Unique prefix match across all aliases and keys
  local candidate="" count=0
  local entry key
  for entry in "${!_TPM_ALIAS_TO_KEY[@]}"; do
    if [[ "$entry" == "$query"* ]]; then
      key="${_TPM_ALIAS_TO_KEY[$entry]}"
      # De-duplicate: multiple aliases may map to the same key.
      if [[ "$key" != "$candidate" ]]; then
        candidate="$key"
        (( ++count ))
      fi
      (( count > 1 )) && break
    fi
  done

  if (( count == 1 )); then
    printf '%s\n' "$candidate"
  fi
}

# --- Agent status ---
#
# Sessions may host one or more AI agents (opencode, claudecode, ...). Each
# agent writes its own tmux session option:
#
#   @tpm-agent-status-<source>-<id> = <state>
#
# The picker doesn't read those directly. A cheap aggregator resolves the
# highest-priority state across all sources and writes it to a single option:
#
#   @tpm-agent-status = <state>   # aggregated, one read per session
#
# Priority (high → low):  needs-input > error > done > working > ready
#
# `ready` and `""` render nothing. `done` is cleared automatically when the
# user focuses the session (see update-status.sh).

# Numeric priority for a state. Higher wins.
agent_status_priority() {
  case "${1:-}" in
    needs-input) echo 4 ;;
    error)       echo 3 ;;
    done)        echo 2 ;;
    working)     echo 1 ;;
    ready)       echo 0 ;;
    *)           echo 0 ;;
  esac
}

# Read the aggregated agent status for a session. Empty if unset.
get_agent_status() {
  local session_name="$1"
  tmux show-option -t "=$session_name:" -qv "$TPM_AGENT_STATUS_OPT" 2>/dev/null
}

# Write a per-source state and recompute the aggregate.
# Usage: set_agent_status <session> <source> <id> <state>
set_agent_status() {
  local session_name="$1" source="$2" id="$3" state="$4"
  [[ -z "$session_name" || -z "$source" || -z "$id" || -z "$state" ]] && return 1
  if ! tmux has-session -t "=$session_name" 2>/dev/null; then
    return 1
  fi
  tmux set-option -t "=$session_name:" "${TPM_AGENT_STATUS_PREFIX}${source}-${id}" "$state" 2>/dev/null
  recompute_agent_status "$session_name"
}

# Clear a per-source entry and recompute.
# Usage: clear_agent_source <session> <source> <id>
clear_agent_source() {
  local session_name="$1" source="$2" id="$3"
  [[ -z "$session_name" || -z "$source" || -z "$id" ]] && return 1
  if ! tmux has-session -t "=$session_name" 2>/dev/null; then
    return 1
  fi
  tmux set-option -t "=$session_name:" -u "${TPM_AGENT_STATUS_PREFIX}${source}-${id}" 2>/dev/null || true
  recompute_agent_status "$session_name"
}

# Enumerate the per-source status options for a session.
# Prints one "<option_name> <value>" per line (tmux's native format). The
# option prefix filter excludes the aggregate @tpm-agent-status option itself.
list_agent_status_sources() {
  local session_name="$1"
  # tmux show-options output: `@tpm-agent-status-opencode-oc-123 "needs-input"`
  # We keep tmux's whitespace separator and dequote inline where needed.
  tmux show-options -t "=$session_name:" 2>/dev/null \
    | grep -E "^${TPM_AGENT_STATUS_PREFIX}" || true
}

# Read every per-source state, pick the highest-priority one, and write it to
# @tpm-agent-status. If nothing is set, unset the aggregate.
recompute_agent_status() {
  local session_name="$1"
  if ! tmux has-session -t "=$session_name" 2>/dev/null; then
    return 0
  fi

  local best_state="" best_prio=-1
  local line name value prio
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Split on the first space: "name value" (value may be quoted).
    name="${line%% *}"
    value="${line#* }"
    value="${value#\"}"
    value="${value%\"}"
    [[ -z "$value" ]] && continue
    prio=$(agent_status_priority "$value")
    if (( prio > best_prio )); then
      best_prio=$prio
      best_state="$value"
    fi
  done < <(list_agent_status_sources "$session_name")

  if [[ -z "$best_state" ]]; then
    tmux set-option -t "=$session_name:" -u "$TPM_AGENT_STATUS_OPT" 2>/dev/null || true
  else
    tmux set-option -t "=$session_name:" "$TPM_AGENT_STATUS_OPT" "$best_state" 2>/dev/null || true
  fi
}

# Clear the `done` marker for a session when the user focuses it. Called from
# update-status.sh on client-session-changed. Leaves needs-input / error alone
# because those need explicit agent-side resolution.
acknowledge_agent_status() {
  local session_name="$1"
  [[ -z "$session_name" ]] && return 0
  local current
  current=$(get_agent_status "$session_name")
  if [[ "$current" == "done" ]]; then
    # Clear every per-source entry that reports `done`, then recompute.
    local line name value
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%% *}"
      value="${line#* }"
      value="${value#\"}"
      value="${value%\"}"
      if [[ "$value" == "done" ]]; then
        tmux set-option -t "=$session_name:" -u "$name" 2>/dev/null || true
      fi
    done < <(list_agent_status_sources "$session_name")
    recompute_agent_status "$session_name"
  fi
}

# Row-scoped ack. Clears a specific per-source `done` marker if — and only
# if — its current state is `done`. Returns 0 on clear, 1 otherwise (with
# the option left untouched). Used by the dashboard's alt-a which operates
# at agent-session granularity, unlike acknowledge_agent_status which folds
# every done in the tmux session at once (that variant is right for
# focus-driven ack, where the human has physically seen the whole session).
acknowledge_agent_source() {
  local session_name="$1" source="$2" id="$3"
  [[ -z "$session_name" || -z "$source" || -z "$id" ]] && return 1
  local key="${TPM_AGENT_STATUS_PREFIX}${source}-${id}"
  local current
  current=$(tmux show-option -t "=$session_name:" -qv "$key" 2>/dev/null)
  [[ "$current" != "done" ]] && return 1
  tmux set-option -t "=$session_name:" -u "$key" 2>/dev/null || true
  recompute_agent_status "$session_name"
  return 0
}

# --- Tmux helpers ---

tmux_base_index() {
  local idx
  idx=$(tmux show-option -gv base-index 2>/dev/null)
  echo "${idx:-0}"
}

window_exists() {
  local session_name="$1" win_name="$2"
  tmux list-windows -t "=$session_name" -F '#{window_name}' 2>/dev/null \
    | grep -qx -- "$win_name"
}

# --- LRU tracking ---
# Stores epoch timestamps per project key in a simple key=timestamp file.
# Used by the picker to sort by most-recently-used when LRU mode is active.

TPM_LRU_FILE="${TPM_STATE_PREFIX}-lru"

# Record a switch/launch timestamp for a project key.
record_lru() {
  local key="$1"
  [[ -z "$key" ]] && return 0
  local ts
  ts=$(date +%s)
  # Atomic update: remove old entry, append new one.
  if [[ -f "$TPM_LRU_FILE" ]]; then
    grep -v "^${key}=" "$TPM_LRU_FILE" > "${TPM_LRU_FILE}.tmp" 2>/dev/null || true
    mv "${TPM_LRU_FILE}.tmp" "$TPM_LRU_FILE"
  fi
  printf '%s=%s\n' "$key" "$ts" >> "$TPM_LRU_FILE"
}

# Get the LRU timestamp for a project key (0 if never accessed).
get_lru_timestamp() {
  local key="$1"
  [[ ! -f "$TPM_LRU_FILE" ]] && printf '0\n' && return 0
  local line
  line=$(grep "^${key}=" "$TPM_LRU_FILE" 2>/dev/null | tail -1)
  if [[ -n "$line" ]]; then
    printf '%s\n' "${line#*=}"
  else
    printf '0\n'
  fi
}

# --- Dashboard helpers ---
#
# Small primitives shared between dashboard.sh, its preview, and the
# integrations/*-tpm-resume.sh hooks. The dashboard itself owns the enumeration
# logic; anything reusable across scripts (time formatting, pane index, stat
# portability) lives here.

TPM_CLAUDE_DIR="${TPM_CLAUDE_DIR:-$HOME/.claude}"
TPM_OPENCODE_DB="${TPM_OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
TPM_DASHBOARD_CUTOFF_DAYS="${TPM_DASHBOARD_CUTOFF_DAYS:-7}"

# Current epoch in milliseconds.
tpm_now_ms() {
  printf '%s\n' "$(($(date +%s) * 1000))"
}

# Human-readable age from an epoch-ms timestamp: "3s", "12m", "2h", "1d".
tpm_ms_since() {
  local ms="${1:-0}" now diff
  now=$(($(date +%s) * 1000))
  diff=$(( (now - ms) / 1000 ))
  (( diff < 0 )) && diff=0
  if   (( diff < 60 ));    then printf '%ds\n' "$diff"
  elif (( diff < 3600 ));  then printf '%dm\n' "$((diff / 60))"
  elif (( diff < 86400 )); then printf '%dh\n' "$((diff / 3600))"
  else                          printf '%dd\n' "$((diff / 86400))"
  fi
}

# Portable file mtime in epoch seconds. Handles the GNU-coreutils-in-PATH case
# that tripped the PoC: `stat -f '%m'` means "filesystem info" on GNU stat,
# not format. On macOS force /usr/bin/stat; elsewhere use GNU `stat -c '%Y'`.
tpm_stat_mtime() {
  local f="$1"
  if [[ "$OSTYPE" == darwin* ]] && [[ -x /usr/bin/stat ]]; then
    /usr/bin/stat -f '%m' "$f" 2>/dev/null
  else
    stat -c '%Y' "$f" 2>/dev/null
  fi
}

# Emit one line per tmux pane, augmented with the pane's direct children so
# callers can match agents that run as a child of the shell (Claude Code).
# Format: session|win.pane|pane_pid|pane_current_command|pane_current_path|child_pids_space_sep
list_agent_panes() {
  command -v tmux >/dev/null 2>&1 || return 0
  tmux info >/dev/null 2>&1 || return 0
  local sess loc ppid cmd cpath children
  while IFS='|' read -r sess loc ppid cmd cpath; do
    [[ -z "$ppid" ]] && continue
    children="$(pgrep -P "$ppid" 2>/dev/null | tr '\n' ' ')"
    printf '%s|%s|%s|%s|%s|%s\n' "$sess" "$loc" "$ppid" "$cmd" "$cpath" "${children% }"
  done < <(tmux list-panes -a -F \
    '#{session_name}|#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}' \
    2>/dev/null)
}
