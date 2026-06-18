#!/usr/bin/env bash
# preview.sh — Render the preview pane for the project picker.
# Usage: preview.sh <session_name>
# Resolves project info from YAML using the session name (alias).

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

session_name="$1"
[[ -z "$session_name" ]] && exit 0

# Resolve session name (alias) to project key
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
  echo ""

  # Window list
  echo "Windows:"
  tmux list-windows -t "=$session_name" -F '  #{window_index}: #{window_name} (#{pane_current_command})' 2>/dev/null
  echo ""
else
  echo "Session: NOT RUNNING"
  echo ""
fi

# --- Git Info ---
if [[ -d "$project_path/.git" ]]; then
  echo "Git:"
  branch=$(git -C "$project_path" branch --show-current 2>/dev/null)
  [[ -n "$branch" ]] && echo "  Branch: $branch"

  # Short status (max 5 lines)
  git_status=$(git -C "$project_path" status --short 2>/dev/null | head -5)
  if [[ -n "$git_status" ]]; then
    echo "  Status:"
    echo "$git_status" | sed 's/^/    /'
    total=$(git -C "$project_path" status --short 2>/dev/null | wc -l | tr -d ' ')
    if (( total > 5 )); then
      echo "    ... and $((total - 5)) more"
    fi
  else
    echo "  Status: clean"
  fi
  echo ""
fi

# --- Config ---
tool=$(get_tool "$project_key")
editor=$(get_editor "$project_key")
echo "Config:"
echo "  Tool:   $tool"
if has_editor "$project_key"; then
  echo "  Editor: $editor"
else
  echo "  Editor: disabled"
fi
echo ""

# --- Action Hints ---
echo "Actions:"
echo "  enter   → switch (launch if needed)"
echo "  ctrl-r  → repair windows"
echo "  ctrl-x  → kill session"
echo "  ctrl-n  → new shell window"
echo "  ctrl-e  → ensure editor window"
echo "  ctrl-f  → toggle filter (all/running)"
