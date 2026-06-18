#!/usr/bin/env bash
# update-status.sh — Update the #{project-name} status variable.
# Called by the client-session-changed hook.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/utils.sh"

current_session=$(tmux display-message -p '#{session_name}')

if is_managed_session "$current_session"; then
  tmux set-option -g @project-name "$current_session"
else
  tmux set-option -g @project-name ""
fi
