#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# opencode-tpm-resume.sh — routing hook for detached OpenCode rows.
#
# Called by dashboard.sh when the user hits Enter on a detached OpenCode row.
# Contract (see integrations/README.md):
#   argv: <session_id> <project_key> <project_path> <tmux_session_name-or-empty>
#   env:  TPM_WINDOW_TOOL, TPM_WINDOW_EDITOR exported by the caller.
#
# OpenCode's process model is 1-process-N-sessions. We cannot reliably
# instruct a running OpenCode TUI to switch to a specific session id (the
# plugin API doesn't expose that operation as of this writing). For v1 we
# therefore route the user to the project's OpenCode presence rather than
# to the specific session:
#
#   1. If a managed tmux session for the project exists AND a window running
#      OpenCode already exists → focus it. Session id is not resumed.
#   2. Else, if the project's configured tool is OpenCode → repair the
#      session (creates $TPM_WINDOW_TOOL if missing) and focus the tool
#      window. Same effect as clicking "opencode" for that project in the
#      picker.
#   3. Else, if no managed tmux session exists at all → launch it via
#      scripts/launch.sh (which will create the tool window with the
#      project's configured tool — may or may not be opencode).
#   4. Else (managed session exists but project's tool isn't opencode) →
#      surface an error. The row shouldn't have been surfaced here; this is
#      a defensive backstop.
#
# The session_id argument is displayed in the message so users can manually
# `/sessions` to it inside the TUI if they really want that specific one.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$CURRENT_DIR/../scripts" && pwd)"
# shellcheck source=../scripts/utils.sh
source "$SCRIPTS_DIR/utils.sh"

session_id="${1:-}"
project_key="${2:-}"
project_path="${3:-}"
tmux_session_name="${4:-}"

if [[ -z "$project_key" ]]; then
  echo "opencode-resume: project_key required" >&2
  exit 1
fi

load_projects_cache

if [[ -z "$tmux_session_name" ]]; then
  tmux_session_name=$(get_session_name "$project_key")
fi

if [[ -z "$project_path" ]]; then
  project_path=$(get_path "$project_key")
fi

if [[ -z "$project_path" || ! -d "$project_path" ]]; then
  tmux display-message "tpm: opencode-resume: project path missing for '$project_key'"
  exit 1
fi

project_tool=$(get_tool "$project_key")

# Find the first window in the managed session whose pane_current_command is
# `opencode.exe` (tmux normalises the process name that way). Returns
# "session:window_name" or empty.
find_opencode_window() {
  local sess="$1" line win cmd
  tmux has-session -t "=$sess" 2>/dev/null || return 1
  while IFS='|' read -r win cmd; do
    [[ "$cmd" == "opencode"* ]] && printf '%s\n' "$win" && return 0
  done < <(tmux list-panes -t "=$sess" -F '#{window_name}|#{pane_current_command}' 2>/dev/null)
  return 1
}

# Case 3 — no managed tmux session at all. Launch and stop; if the launched
# tool is opencode the user lands directly in the tool window (launch.sh
# selects it). If it isn't, the user still gets the project's normal layout.
if ! tmux has-session -t "=$tmux_session_name" 2>/dev/null; then
  "$SCRIPTS_DIR/launch.sh" "$project_key"
  exit 0
fi

# Case 1 — session exists, look for a live opencode window.
if oc_window=$(find_opencode_window "$tmux_session_name"); then
  tmux switch-client -t "=${tmux_session_name}:${oc_window}"
  exit 0
fi

# Case 2 — no live opencode in the session. If the project's configured tool
# is opencode, repair (creates $TPM_WINDOW_TOOL if missing) and focus it.
if [[ "$project_tool" == opencode* ]]; then
  "$SCRIPTS_DIR/repair.sh" "$tmux_session_name" >/dev/null
  tmux select-window -t "=${tmux_session_name}:${TPM_WINDOW_TOOL}"
  tmux switch-client -t "=${tmux_session_name}"
  exit 0
fi

# Case 4 — defensive. Managed session exists but the project doesn't run
# opencode as its tool; there's no opencode window to route to. Tell the user
# rather than silently creating a floating window.
tmux display-message "tpm: '$project_key' has no opencode presence (tool: $project_tool). Session: ${session_id:-?}"
exit 0
