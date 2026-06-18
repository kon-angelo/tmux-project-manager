#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# tmux-project-manager — TPM entry point
# Manages project sessions with a unified picker, repair, and cycling.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# --- Option defaults ---
# M-{ / M-} (Shift+[ / Shift+]) avoid the CSI/OSC escape prefix conflict that
# breaks bare M-[ and M-] in most terminals (Alt+[ generates ESC[ which is the
# CSI control-sequence prefix; the terminal eats it before tmux sees it).
default_projects_file="$HOME/.config/projects/projects.yaml"
default_tool="opencode"
default_editor="nvim"
default_picker_key="M-p"
default_prev_key="M-{"
default_next_key="M-}"

# --- Read tmux options (with defaults) ---
get_opt() {
  local opt="$1" default="$2"
  local val
  val=$(tmux show-option -gqv "$opt")
  echo "${val:-$default}"
}

projects_file=$(get_opt "@tpm-projects-file" "$default_projects_file")
picker_key=$(get_opt "@tpm-picker-key" "$default_picker_key")
prev_key=$(get_opt "@tpm-prev-key" "$default_prev_key")
next_key=$(get_opt "@tpm-next-key" "$default_next_key")

# --- Export config for scripts ---
tmux set-environment -g TPM_PROJECTS_FILE "$projects_file"
tmux set-environment -g TPM_DEFAULT_TOOL "$(get_opt "@tpm-default-tool" "$default_tool")"
tmux set-environment -g TPM_DEFAULT_EDITOR "$(get_opt "@tpm-default-editor" "$default_editor")"
tmux set-environment -g TPM_SCRIPTS_DIR "$SCRIPTS_DIR"

# --- Bind keys ---
tmux bind-key -n "$picker_key" run-shell -b "$SCRIPTS_DIR/picker.sh"
tmux bind-key -n "$prev_key" run-shell -b "$SCRIPTS_DIR/cycle.sh prev"
tmux bind-key -n "$next_key" run-shell -b "$SCRIPTS_DIR/cycle.sh next"

# --- Status bar format variable ---
# #{project-name} resolves to the current project session name if managed
tmux set-option -g @project-name ""
tmux set-hook -g client-session-changed "run-shell -b '$SCRIPTS_DIR/update-status.sh'"
