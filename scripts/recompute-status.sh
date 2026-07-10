#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# recompute-status.sh — thin wrapper around utils.sh's recompute_agent_status.
# Called by external clients (opencode plugin, Claude Code hook) after they
# write a per-source @tpm-agent-status-<source>-<id> option, so the
# aggregate @tpm-agent-status option stays in sync.
#
# Usage: recompute-status.sh <session-name>
#
# Exit codes:
#   0  aggregate recomputed (may be unset if no sources are set)
#   1  session does not exist, or no session name given

set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

session_name="${1:-}"
if [[ -z "$session_name" ]]; then
  echo "Usage: recompute-status.sh <session-name>" >&2
  exit 1
fi

if ! tmux has-session -t "=$session_name" 2>/dev/null; then
  exit 1
fi

recompute_agent_status "$session_name"
