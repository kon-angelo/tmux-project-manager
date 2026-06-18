#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# retag.sh — Re-apply project-managed status to existing sessions.
# Designed to be bound to the tmux-resurrect post-restore hook so that
# sessions restored from disk regain their @tpm-managed tag and project-key
# option (resurrect does not preserve session-scoped user options).
#
# Usage: retag.sh
#
# Behaviour:
#   - Iterates every existing tmux session.
#   - For each session whose name matches a known project alias/key,
#     sets @tpm-managed=1 and @tpm-project-key=<canonical key>.
#   - Sessions that do not correspond to any project are left alone.
#
# Idempotent — re-running is a no-op for already-tagged sessions.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

if ! validate_projects_file; then
  exit 0
fi

load_projects_cache
load_session_cache

retagged=0
# Iterate the cached session list (loaded above) — avoids spawning another
# tmux list-sessions and lets us reuse the array.
for session in "${_TPM_SESSION_LIST[@]}"; do
  [[ -z "$session" ]] && continue

  # Resolve the session name to a project key (in-memory hash lookup).
  project_key=$(resolve_project_key "$session")
  [[ -z "$project_key" ]] && continue

  # Guard: only tag if the name matches the canonical session name for the
  # project (i.e. the first alias). Prevents accidentally tagging a session
  # whose name happens to equal a project's full key but not its alias.
  expected_session=$(get_session_name "$project_key")
  [[ "$expected_session" != "$session" ]] && continue

  # set-option is idempotent and cheap; skip the prior show-option pre-check
  # which was costing more than it saved (one tmux IPC roundtrip per session).
  tag_session "$session" "$project_key"
  retagged=$((retagged + 1))
done

# Best-effort status update for the format variable.
if [[ -x "$CURRENT_DIR/update-status.sh" ]]; then
  "$CURRENT_DIR/update-status.sh" 2>/dev/null || true
fi

# Stay silent on success — the hook fires on every restore and we don't want
# noisy display-messages.
exit 0
