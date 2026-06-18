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

retagged=0
while IFS= read -r session; do
  [[ -z "$session" ]] && continue

  # Skip sessions that already carry the tag.
  current=$(tmux show-option -t "=$session:" -qv "$TPM_TAG" 2>/dev/null)
  if [[ "$current" == "1" ]]; then
    continue
  fi

  # Try to resolve the session name to a project key.
  project_key=$(resolve_project_key "$session")
  if [[ -z "$project_key" ]]; then
    continue
  fi

  # Verify the session name matches the canonical session name for the
  # project — guards against accidental tagging of sessions that happen to
  # share a name with a project's full key but not its primary alias.
  expected_session=$(get_session_name "$project_key")
  if [[ "$expected_session" != "$session" ]]; then
    continue
  fi

  tag_session "$session" "$project_key"
  retagged=$((retagged + 1))
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

# Best-effort status update for the format variable.
if [[ -x "$CURRENT_DIR/update-status.sh" ]]; then
  "$CURRENT_DIR/update-status.sh" 2>/dev/null || true
fi

# Stay silent on success — the hook fires on every restore and we don't want
# noisy display-messages.
exit 0
