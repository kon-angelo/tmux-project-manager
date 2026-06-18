#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# update-status.sh — Update the @project-name option to reflect the current session.
# Bound to the client-session-changed hook.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

load_projects_cache

current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")

if [[ -n "$current_session" ]] && is_managed_session "$current_session"; then
  tmux set-option -g @project-name "$current_session"
else
  tmux set-option -g @project-name ""
fi
