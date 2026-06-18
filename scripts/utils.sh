#!/usr/bin/env bash
# utils.sh — Shared utilities for tmux-project-manager
# Sources: YAML parsing, session tagging, current project detection.

# --- Environment ---
TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$(tmux show-environment -g TPM_PROJECTS_FILE 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-$(tmux show-environment -g TPM_DEFAULT_TOOL 2>/dev/null | cut -d= -f2-)}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-$(tmux show-environment -g TPM_DEFAULT_EDITOR 2>/dev/null | cut -d= -f2-)}"
TPM_SCRIPTS_DIR="${TPM_SCRIPTS_DIR:-$(tmux show-environment -g TPM_SCRIPTS_DIR 2>/dev/null | cut -d= -f2-)}"

TPM_PROJECTS_FILE="${TPM_PROJECTS_FILE:-$HOME/.config/projects/projects.yaml}"
TPM_DEFAULT_TOOL="${TPM_DEFAULT_TOOL:-opencode}"
TPM_DEFAULT_EDITOR="${TPM_DEFAULT_EDITOR:-nvim}"

# Tag used to identify project-managed sessions
TPM_TAG="@tpm-managed"

# --- YAML Parsing ---

# List all project keys (excluding _ prefixed special entries)
list_project_keys() {
  yq -r 'keys | .[] | select(test("^[^_]"))' "$TPM_PROJECTS_FILE" 2>/dev/null
}

# Get a field for a project key. Usage: get_field <key> <field>
# Note: stdin is closed (< /dev/null) to prevent yq from consuming pipe input
# when called inside while-read loops.
get_field() {
  local key="$1" field="$2"
  yq -r ".[\"$key\"].$field // \"\"" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null
}

# Get the first alias (session name) for a project key
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

# Get project path
get_path() {
  get_field "$1" "path"
}

# Get tool command for a project
get_tool() {
  local key="$1"
  local tool
  tool=$(get_field "$key" "tool")
  echo "${tool:-$TPM_DEFAULT_TOOL}"
}

# Get editor command for a project
get_editor() {
  local key="$1"
  local editor
  editor=$(get_field "$key" "editor")
  echo "${editor:-$TPM_DEFAULT_EDITOR}"
}

# Check if editor window is enabled for a project
has_editor() {
  local key="$1"
  local nvim_val
  nvim_val=$(get_field "$key" "nvim")
  # Default is true; only false if explicitly set to false
  [[ "$nvim_val" != "false" ]]
}

# Get description
get_description() {
  get_field "$1" "description"
}

# --- Project List (for picker) ---

# Output: tab-separated lines of "session_name\tkey\tpath\tdescription\trunning"
list_projects() {
  local keys key session_name path desc running
  while IFS= read -r key; do
    session_name=$(get_session_name "$key")
    path=$(get_path "$key")
    desc=$(get_description "$key")
    # Check if session exists
    if tmux has-session -t "=$session_name" 2>/dev/null; then
      running="running"
    else
      running="stopped"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$session_name" "$key" "$path" "$desc" "$running"
  done < <(list_project_keys)
}

# --- Current Project Detection ---

# Longest prefix match of a path against all project paths.
# Returns the project key (not session name).
detect_current_project() {
  local cwd="${1:-$(tmux display-message -p '#{pane_current_path}')}"
  local best_key="" best_len=0
  local key project_path plen

  while IFS= read -r key; do
    project_path=$(get_path "$key")
    [[ -z "$project_path" ]] && continue
    # Check if cwd starts with project_path
    if [[ "$cwd" == "$project_path"* ]]; then
      plen=${#project_path}
      if (( plen > best_len )); then
        best_len=$plen
        best_key="$key"
      fi
    fi
  done < <(list_project_keys)

  echo "$best_key"
}

# Detect current project and return session name
detect_current_session_name() {
  local key
  key=$(detect_current_project "$@")
  if [[ -n "$key" ]]; then
    get_session_name "$key"
  fi
}

# --- Session Tagging ---

# Mark a session as managed by this plugin
tag_session() {
  local session_name="$1"
  tmux set-option -t "=$session_name" "$TPM_TAG" "1" 2>/dev/null
}

# Check if a session is managed
is_managed_session() {
  local session_name="$1"
  local val
  val=$(tmux show-option -t "=$session_name" -qv "$TPM_TAG" 2>/dev/null)
  [[ "$val" == "1" ]]
}

# List all managed session names
list_managed_sessions() {
  local session
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r session; do
    if is_managed_session "$session"; then
      echo "$session"
    fi
  done
}

# --- Key-to-Session Resolution ---

# Given an alias or key, find the project key
resolve_project_key() {
  local query="$1"
  local key aliases

  # First check if it's a direct key
  if yq -e ".[\"$query\"]" "$TPM_PROJECTS_FILE" < /dev/null &>/dev/null; then
    echo "$query"
    return
  fi

  # Check aliases
  while IFS= read -r key; do
    aliases=$(yq -r ".[\"$key\"].aliases // [] | .[]" "$TPM_PROJECTS_FILE" < /dev/null 2>/dev/null)
    while IFS= read -r alias; do
      if [[ "$alias" == "$query" ]]; then
        echo "$key"
        return
      fi
    done <<< "$aliases"
  done < <(list_project_keys)
}
