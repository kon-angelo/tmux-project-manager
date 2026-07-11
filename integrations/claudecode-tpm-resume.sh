#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# claudecode-tpm-resume.sh — resume-a-detached-session hook for Claude Code.
#
# Called by dashboard.sh when the user hits Enter on a detached Claude row.
# Contract (see integrations/README.md):
#   argv: <session_id> <project_key> <project_path> <tmux_session_name-or-empty>
#   env:  TPM_WINDOW_TOOL, TPM_WINDOW_EDITOR exported by the caller.
#
# Claude Code is 1-process-1-session. We can reliably resume a specific
# session with `claude --resume <uuid>`. Behaviour:
#
#   1. If no managed tmux session for the project → run scripts/launch.sh to
#      create one; then continue to step 2 in the newly-created session.
#   2. Open (or reuse) a window named "claude:<short-uuid>" running
#      `claude --resume <uuid>`. Reusing keeps repeat-clicks idempotent.
#   3. Switch the client to the target session + window.
#
# The project's tool window is left untouched — it may be running opencode,
# a shell, or nothing at all; that's not our concern.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$CURRENT_DIR/../scripts" && pwd)"
# shellcheck source=../scripts/utils.sh
source "$SCRIPTS_DIR/utils.sh"

session_id="${1:-}"
project_key="${2:-}"
project_path="${3:-}"
tmux_session_name="${4:-}"

if [[ -z "$session_id" || -z "$project_key" ]]; then
  echo "claudecode-resume: session_id and project_key required" >&2
  exit 1
fi

load_projects_cache

# Resolve target tmux session name. If caller didn't supply one (or the one it
# supplied is stale), derive it from the project key.
if [[ -z "$tmux_session_name" ]]; then
  tmux_session_name=$(get_session_name "$project_key")
fi

if [[ -z "$project_path" ]]; then
  project_path=$(get_path "$project_key")
fi

if [[ -z "$project_path" || ! -d "$project_path" ]]; then
  tmux display-message "tpm: claude-resume: project path missing for '$project_key'"
  exit 1
fi

# Step 1 — ensure the managed session exists. launch.sh is idempotent: if the
# session is already there and managed it just no-ops. Use --background so we
# don't switch the client yet; we'll switch to the resume window explicitly.
if ! tmux has-session -t "=$tmux_session_name" 2>/dev/null; then
  "$SCRIPTS_DIR/launch.sh" --background "$project_key" >/dev/null || {
    tmux display-message "tpm: claude-resume: failed to launch session '$tmux_session_name'"
    exit 1
  }
  invalidate_session_cache
fi

# Step 2 — window name. Short-UUID keeps the window bar readable and enables
# trivial dedupe (same session_id → same window name → reuse).
short_id="${session_id:0:8}"
window_name="claude:${short_id}"

if window_exists "$tmux_session_name" "$window_name"; then
  # Already open — just focus it.
  tmux select-window -t "=${tmux_session_name}:${window_name}"
else
  # Quote the session_id so shell metacharacters in the id (extremely
  # unlikely, but safe) don't break the command form.
  tmux new-window -t "=$tmux_session_name" -n "$window_name" \
    -c "$project_path" "claude --resume $(printf '%q' "$session_id")"
fi

# Step 3 — bring the client to the target session + window.
tmux switch-client -t "=${tmux_session_name}:${window_name}"
