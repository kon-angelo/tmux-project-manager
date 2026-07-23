#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# preview.sh — Render the right-pane preview for the project picker.
# Usage: preview.sh <session_name>

set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

load_projects_cache

session_name="${1:-}"
[[ -z "$session_name" ]] && exit 0

project_key=$(resolve_project_key "$session_name")
if [[ -z "$project_key" ]]; then
  echo "Unknown project: $session_name"
  exit 0
fi

project_path=$(get_path "$project_key")
desc=$(get_description "$project_key")

# --- Header ---
echo "Project: $session_name ($project_key)"
echo "Path:    $project_path"
[[ -n "$desc" ]] && echo "Desc:    $desc"
echo ""

# --- Session State ---
if tmux has-session -t "=$session_name" 2>/dev/null; then
  echo "Session: RUNNING"

  agent_status=$(get_agent_status "$session_name")
  if [[ -n "$agent_status" ]]; then
    echo "Agent:   $agent_status"
    # List per-source contributors when there is more than one, so the user
    # can see which agent is asking for input.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%% *}"
      value="${line#* }"
      value="${value#\"}"
      value="${value%\"}"
      # Strip prefix, leaving "<source>-<id>".
      short="${name#${TPM_AGENT_STATUS_PREFIX}}"
      echo "         - $short: $value"
    done < <(list_agent_status_sources "$session_name")
  fi
  echo ""
  echo "Windows:"
  tmux list-windows -t "=$session_name" \
    -F '  #{window_index}: #{window_name} (#{pane_current_command})' 2>/dev/null
  echo ""
else
  echo "Session: NOT RUNNING"
  echo ""
fi

# --- Git Info ---
if [[ -d "$project_path/.git" ]]; then
  echo "Git:"
  branch=$(git -C "$project_path" branch --show-current 2>/dev/null || true)
  [[ -n "$branch" ]] && echo "  Branch: $branch"

  git_status=$(git -C "$project_path" status --short 2>/dev/null || true)
  if [[ -n "$git_status" ]]; then
    echo "  Status:"
    printf '%s\n' "$git_status" | head -5 | sed 's/^/    /'
    total=$(printf '%s\n' "$git_status" | wc -l | tr -d ' ')
    if (( total > 5 )); then
      echo "    ... and $((total - 5)) more"
    fi
  else
    echo "  Status: clean"
  fi
  echo ""
fi

# --- Config ---
echo "Config:"
echo "  Tool:   $(get_tool "$project_key")"
if has_editor "$project_key"; then
  echo "  Editor: $(get_editor "$project_key")"
else
  echo "  Editor: disabled"
fi
echo ""

# --- Action Hints ---
echo "Actions:"
echo "  enter   → switch (launch if needed)"
echo "  M-r     → repair windows"
echo "  M-x     → kill session"
echo "  M-n     → new shell window"
echo "  M-e     → ensure editor window"
echo "  M-f     → toggle filter (all/running)"
