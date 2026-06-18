#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# utils.sh — Shared utilities for tmux-project-manager
# YAML parsing, session tagging, current-project detection.

# --- Environment ---
TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$(tmux show-environment -g TPM_PROJECTS_FILE 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-$(tmux show-environment -g TPM_DEFAULT_TOOL 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-$(tmux show-environment -g TPM_DEFAULT_EDITOR 2>/dev/null | cut -d= -f2-)}"
TPM_SCRIPTS_DIR="${TPM_SCRIPTS_DIR:-$(tmux show-environment -g TPM_SCRIPTS_DIR 2>/dev/null | cut -d= -f2-)}"

TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$HOME/.config/projects/projects.yaml}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-opencode}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-nvim}"

# --- Constants ---
TPM_TAG="@tpm-managed"                     # Per-session option marking a managed session
TPM_PROJECT_KEY_OPT="@tpm-project-key"     # Per-session option storing the project key
TPM_WINDOW_TOOL="claude"                   # Window name for AI tool
TPM_WINDOW_EDITOR="editor"                 # Window name for editor
TPM_TMP_DIR="${TMPDIR:-/tmp}"
TPM_STATE_PREFIX="${TPM_TMP_DIR%/}/tpm-${USER:-default}"

# --- Validation ---

# Check that the projects file exists and is parseable.
# On error: writes to stderr and returns non-zero.
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

# --- YAML Parsing ---
# Note: all yq calls redirect stdin from /dev/null to avoid consuming pipe input
# when these helpers are used inside while-read loops (subshells inherit FD 0).

# List all project keys (excluding _-prefixed special entries).
list_project_keys() {
  yq -r 'keys | .[] | select(test("^[^_]"))' "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null
}

# Get a single field for a project key. Usage: get_field <key> <field>
get_field() {
  local key="$1" field="$2"
  yq -r ".[\"$key\"].$field // \"\"" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null
}

# Get the first alias (used as the tmux session name). Falls back to the key itself.
get_session_name() {
  local key="$1"
  local first_alias
  first_alias=$(yq -r ".[\"$key\"].aliases[0] // \"\"" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null)
  if [[ -n "$first_alias" ]]; then
    echo "$first_alias"
  else
    echo "$key"
  fi
}

get_path()        { get_field "$1" "path"; }
get_description() { get_field "$1" "description"; }

get_tool() {
  local key="$1" tool
  tool=$(get_field "$key" "tool")
  echo "${tool:-$TPM_DEFAULT_TOOL}"
}

get_editor() {
  local key="$1" editor
  editor=$(get_field "$key" "editor")
  echo "${editor:-$TPM_DEFAULT_EDITOR}"
}

# Whether a project should have an editor window. Default: true.
has_editor() {
  local key="$1" nvim_val
  nvim_val=$(get_field "$key" "nvim")
  [[ "$nvim_val" != "false" ]]
}

# --- Project List (for picker) ---

# Output: TAB-separated lines: session_name, key, path, description, status (running|stopped)
list_projects() {
  local key session_name path desc running
  while IFS= read -r key; do
    session_name=$(get_session_name "$key")
    path=$(get_path "$key")
    desc=$(get_description "$key")
    if tmux has-session -t "=$session_name" 2>/dev/null; then
      running="running"
    else
      running="stopped"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$session_name" "$key" "$path" "$desc" "$running"
  done < <(list_project_keys)
}

# --- Current-Project Detection ---

# Longest-prefix match of a path against all project paths.
# A path matches a project iff cwd == project_path OR cwd starts with "project_path/".
# Returns the project key (not the session name).
detect_current_project() {
  local cwd="${1:-$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)}"
  [[ -z "$cwd" ]] && return 0

  local best_key="" best_len=0
  local key project_path plen

  while IFS= read -r key; do
    project_path=$(get_path "$key")
    [[ -z "$project_path" ]] && continue
    # Strip a trailing slash from project_path for consistent comparison.
    project_path="${project_path%/}"

    if [[ "$cwd" == "$project_path" || "$cwd" == "$project_path"/* ]]; then
      plen=${#project_path}
      if (( plen > best_len )); then
        best_len=$plen
        best_key="$key"
      fi
    fi
  done < <(list_project_keys)

  echo "$best_key"
}

# Convenience: detect current project and return its session name.
detect_current_session_name() {
  local key
  key=$(detect_current_project "$@")
  if [[ -n "$key" ]]; then
    get_session_name "$key"
  fi
}

# --- Session Tagging ---

# Mark a session as managed by this plugin. Also stores the project key.
# Note: set-option's session target syntax requires a trailing ':' for exact-match
# (`=name:`); a bare `=name` is parsed as a literal session name and fails.
tag_session() {
  local session_name="$1" project_key="${2:-}"
  tmux set-option -t "=$session_name:" "$TPM_TAG" "1" 2>/dev/null
  if [[ -n "$project_key" ]]; then
    tmux set-option -t "=$session_name:" "$TPM_PROJECT_KEY_OPT" "$project_key" 2>/dev/null
  fi
}

# True if a session is project-managed.
# Primary check: the @tpm-managed option is set.
# Fallback: the session name resolves to a known project alias/key — useful after
# tmux-resurrect restores sessions (which doesn't preserve user options reliably).
is_managed_session() {
  local session_name="$1" val key
  val=$(tmux show-option -t "=$session_name:" -qv "$TPM_TAG" 2>/dev/null)
  if [[ "$val" == "1" ]]; then
    return 0
  fi
  # Fallback: name matches a known project
  key=$(resolve_project_key "$session_name")
  if [[ -n "$key" ]]; then
    local expected_session
    expected_session=$(get_session_name "$key")
    if [[ "$expected_session" == "$session_name" ]]; then
      # Re-tag opportunistically so future calls are O(1)
      tag_session "$session_name" "$key"
      return 0
    fi
  fi
  return 1
}

# Get the project key associated with a session, with fallback resolution.
get_session_project_key() {
  local session_name="$1" key
  key=$(tmux show-option -t "=$session_name:" -qv "$TPM_PROJECT_KEY_OPT" 2>/dev/null)
  if [[ -n "$key" ]]; then
    echo "$key"
    return 0
  fi
  # Fallback: derive from session name
  key=$(resolve_project_key "$session_name")
  if [[ -n "$key" ]]; then
    # Cache it
    tmux set-option -t "=$session_name:" "$TPM_PROJECT_KEY_OPT" "$key" 2>/dev/null
    echo "$key"
    return 0
  fi
  return 1
}

# List all managed session names.
list_managed_sessions() {
  local session
  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    if is_managed_session "$session"; then
      echo "$session"
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# --- Key-to-Session Resolution ---

# Resolve an alias or direct key to the canonical project key. Empty if no match.
resolve_project_key() {
  local query="$1"
  [[ -z "$query" ]] && return 0

  # Exact match against a top-level key (skip _-prefixed).
  if [[ "$query" != _* ]] \
     && yq -e ".[\"$query\"]" "$TPM_PROJECTS_FILE" < /dev/null &>/dev/null; then
    echo "$query"
    return 0
  fi

  # Otherwise scan aliases.
  local key aliases alias
  while IFS= read -r key; do
    aliases=$(yq -r ".[\"$key\"].aliases // [] | .[]" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null)
    while IFS= read -r alias; do
      [[ -z "$alias" ]] && continue
      if [[ "$alias" == "$query" ]]; then
        echo "$key"
        return 0
      fi
    done <<< "$aliases"
  done < <(list_project_keys)
}

# --- Tmux Helpers ---

# Window base index (0 or 1 depending on user config).
tmux_base_index() {
  local idx
  idx=$(tmux show-option -gv base-index 2>/dev/null)
  echo "${idx:-0}"
}

# Check if a window with a given name exists in a session.
window_exists() {
  local session_name="$1" win_name="$2"
  tmux list-windows -t "=$session_name" -F '#{window_name}' 2>/dev/null \
    | grep -qx -- "$win_name"
}
