#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# tmux-project-manager — TPM entry point
#
# This file is deliberately minimal: it exports script paths and wires the
# status-bar + resurrect hooks, and does nothing else. The plugin ships
# scripts under scripts/; users bind them with their own `bind-key` lines.
# See README.md → "Recommended bindings" for a copy-paste starting point.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# --- Option defaults (non-key) ---
default_projects_file="$HOME/.config/projects/projects.yaml"
default_tool="opencode"
default_editor="nvim"

# --- Read tmux options (with defaults) ---
get_opt() {
  local opt="$1" default="$2"
  local val
  val=$(tmux show-option -gqv "$opt")
  echo "${val:-$default}"
}

# --- Export config for scripts ---
tmux set-environment -g TPM_PROJECTS_FILE   "$(get_opt "@tpm-projects-file"   "$default_projects_file")"
tmux set-environment -g TPM_DEFAULT_TOOL    "$(get_opt "@tpm-default-tool"    "$default_tool")"
tmux set-environment -g TPM_DEFAULT_EDITOR  "$(get_opt "@tpm-default-editor"  "$default_editor")"
tmux set-environment -g TPM_SCRIPTS_DIR     "$SCRIPTS_DIR"
tmux set-environment -g TPM_BIN             "$CURRENT_DIR/bin"
tmux set-environment -g TPM_INTEGRATIONS_DIR "$CURRENT_DIR/integrations"

# --- Status bar format variable ---
# #{@project-name} resolves to the current project session name if managed.
tmux set-option -g @project-name ""
tmux set-hook -g client-session-changed "run-shell -b '$SCRIPTS_DIR/update-status.sh'"

# --- tmux-resurrect compatibility ---
# tmux-resurrect does not preserve session-scoped user options across
# save/restore, so the @tpm-managed and @tpm-project-key tags are lost when
# sessions are restored. Bind retag.sh to the post-restore-all hook so the
# tags are reapplied based on session names matching project aliases.
#
# We do NOT overwrite an existing @resurrect-hook-post-restore-all value if
# one is already set — instead we append our script to be executed after.
existing_hook=$(tmux show-option -gqv "@resurrect-hook-post-restore-all")
tpm_retag_cmd="$SCRIPTS_DIR/retag.sh"
case "$existing_hook" in
  *"$tpm_retag_cmd"*)
    : # already wired up, no-op
    ;;
  "")
    tmux set-option -g "@resurrect-hook-post-restore-all" "$tpm_retag_cmd"
    ;;
  *)
    tmux set-option -g "@resurrect-hook-post-restore-all" "$existing_hook ; $tpm_retag_cmd"
    ;;
esac
