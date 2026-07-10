#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# claudecode-tpm-status.sh — Claude Code hook script that publishes agent
# status to tmux-project-manager so the tpm picker shows which projects
# need attention.
#
# Reads Claude Code's JSON hook payload from stdin, maps hook_event_name
# to a tpm agent state, and writes @tpm-agent-status-claudecode-<id> on
# the current tmux session. The tpm scripts aggregate across sources.
#
# Event mapping:
#   SessionStart         → ready
#   UserPromptSubmit     → working
#   Stop                 → done
#   PostToolUseFailure   → error
#   PermissionRequest    → needs-input
#   Notification         → needs-input   (Claude Code fires this when
#                                          waiting for user input; treat as
#                                          attention-required)
#   SessionEnd           → clear
#   SubagentStop         → ignored (parent's Stop covers the user-visible
#                                    "done" transition; per-subagent status
#                                    would clutter the picker)
#
# Install in ~/.claude/settings.json:
#
#   {
#     "hooks": {
#       "SessionStart":       [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}],
#       "UserPromptSubmit":   [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}],
#       "Stop":               [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}],
#       "Notification":       [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}],
#       "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}],
#       "SessionEnd":         [{"hooks": [{"type": "command", "command": "/path/to/claudecode-tpm-status.sh"}]}]
#     }
#   }
#
# No-ops silently when not inside a tpm-managed tmux session.

set -uo pipefail

# --- Read stdin payload ---
payload=$(cat -)
[[ -z "$payload" ]] && exit 0

# Extract fields. Prefer jq for robustness; fall back to grep+sed if not
# installed (unlikely on macOS with brew, but keeps the hook resilient).
extract() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg f "$field" '.[$f] // ""'
  else
    printf '%s' "$payload" \
      | grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -1 \
      | sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
  fi
}

event=$(extract "hook_event_name")
session_id=$(extract "session_id")

[[ -z "$event" ]] && exit 0
[[ -z "$session_id" ]] && session_id="pid-$$"

# --- Map event to state ---
state=""
case "$event" in
  SessionStart)                  state="ready"       ;;
  UserPromptSubmit)              state="working"     ;;
  Stop)                          state="done"        ;;
  Notification|PermissionRequest) state="needs-input" ;;
  PostToolUseFailure)            state="error"       ;;
  SessionEnd)                    state="__clear__"   ;;
  *)                             exit 0              ;;
esac

# --- Locate the tmux session ---
[[ -z "${TMUX:-}" ]] && exit 0
command -v tmux >/dev/null 2>&1 || exit 0

tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
[[ -z "$tmux_session" ]] && exit 0

# Only publish into tpm-managed sessions.
tpm_managed=$(tmux show-option -t "=$tmux_session:" -qv "@tpm-managed" 2>/dev/null)
[[ "$tpm_managed" != "1" ]] && exit 0

opt="@tpm-agent-status-claudecode-${session_id}"

if [[ "$state" == "__clear__" ]]; then
  tmux set-option -t "=$tmux_session:" -u "$opt" 2>/dev/null || true
else
  tmux set-option -t "=$tmux_session:" "$opt" "$state" 2>/dev/null || true
fi

# --- Recompute the aggregate ---
# Prefer the bundled recompute script (keeps the aggregation logic in one
# place). Fall back to writing the aggregate directly if the script is
# missing.
scripts_dir="${HOME}/.tmux/plugins/tmux-project-manager/scripts"
if [[ -x "$scripts_dir/recompute-status.sh" ]]; then
  "$scripts_dir/recompute-status.sh" "$tmux_session" >/dev/null 2>&1 || true
  exit 0
fi

# Inline fallback: walk all @tpm-agent-status-* options, pick the highest
# priority, write it into @tpm-agent-status. Keep in sync with utils.sh's
# recompute_agent_status().
priority_of() {
  case "$1" in
    needs-input) echo 4 ;;
    error)       echo 3 ;;
    done)        echo 2 ;;
    working)     echo 1 ;;
    ready)       echo 0 ;;
    *)           echo -1 ;;
  esac
}

best_state=""
best_prio=-1
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  case "$line" in @tpm-agent-status-*) ;; *) continue ;; esac
  name="${line%% *}"
  # Skip the aggregate itself (name = @tpm-agent-status, no dash after -status).
  [[ "$name" == "@tpm-agent-status" ]] && continue
  value="${line#* }"
  value="${value#\"}"
  value="${value%\"}"
  [[ -z "$value" ]] && continue
  prio=$(priority_of "$value")
  if (( prio > best_prio )); then
    best_prio=$prio
    best_state="$value"
  fi
done < <(tmux show-options -t "=$tmux_session:" 2>/dev/null)

if [[ -n "$best_state" ]]; then
  tmux set-option -t "=$tmux_session:" "@tpm-agent-status" "$best_state" 2>/dev/null || true
else
  tmux set-option -t "=$tmux_session:" -u "@tpm-agent-status" 2>/dev/null || true
fi
