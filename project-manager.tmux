#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# tmux-project-manager — TPM entry point
# Manages project sessions with a unified picker, repair, and cycling.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# --- Option defaults ---
# No keybinds are bound by default. Installing the plugin is opt-in for
# every action — pick your own keys via the @tpm-*-key options below.
# Rationale: user keymaps are opinionated (Alt combos, prefix-tables,
# terminal-specific escape sequences). Defaulting anything guarantees a
# collision for someone; better to require an explicit choice.
#
# The @tpm-*-no-prefix options keep their behaviourally-sensible defaults
# ('on' for popups, 'off' for cycle) because they only apply once the
# corresponding key is set — an empty key skips the bind entirely.
default_projects_file="$HOME/.config/projects/projects.yaml"
default_tool="opencode"
default_editor="nvim"
default_picker_key=""
default_picker_no_prefix="on"
default_prev_key=""
default_next_key=""
default_cycle_no_prefix="off"
default_carousel_key=""
default_carousel_no_prefix="on"
default_dashboard_key=""
default_dashboard_no_prefix="on"

# --- Read tmux options (with defaults) ---
get_opt() {
  local opt="$1" default="$2"
  local val
  val=$(tmux show-option -gqv "$opt")
  echo "${val:-$default}"
}

projects_file=$(get_opt "@tpm-projects-file" "$default_projects_file")
picker_key=$(get_opt "@tpm-picker-key" "$default_picker_key")
picker_no_prefix=$(get_opt "@tpm-picker-no-prefix" "$default_picker_no_prefix")
prev_key=$(get_opt "@tpm-prev-key" "$default_prev_key")
next_key=$(get_opt "@tpm-next-key" "$default_next_key")
cycle_no_prefix=$(get_opt "@tpm-cycle-no-prefix" "$default_cycle_no_prefix")
carousel_key=$(get_opt "@tpm-carousel-key" "$default_carousel_key")
carousel_no_prefix=$(get_opt "@tpm-carousel-no-prefix" "$default_carousel_no_prefix")
dashboard_key=$(get_opt "@tpm-dashboard-key" "$default_dashboard_key")
dashboard_no_prefix=$(get_opt "@tpm-dashboard-no-prefix" "$default_dashboard_no_prefix")

# --- Export config for scripts ---
tmux set-environment -g TPM_PROJECTS_FILE "$projects_file"
tmux set-environment -g TPM_DEFAULT_TOOL "$(get_opt "@tpm-default-tool" "$default_tool")"
tmux set-environment -g TPM_DEFAULT_EDITOR "$(get_opt "@tpm-default-editor" "$default_editor")"
tmux set-environment -g TPM_SCRIPTS_DIR "$SCRIPTS_DIR"
tmux set-environment -g TPM_BIN "$CURRENT_DIR/bin"
tmux set-environment -g TPM_INTEGRATIONS_DIR "$CURRENT_DIR/integrations"

# --- Bind keys ---
# Every binding is opt-in: an empty @tpm-*-key skips the block entirely.
# The @tpm-*-no-prefix option flips between the root and prefix key tables.
#
# Picker: fzf-based project switcher.
if [[ -n "$picker_key" ]]; then
  if [[ "$picker_no_prefix" == "on" ]]; then
    tmux bind-key -n "$picker_key" run-shell -b "$SCRIPTS_DIR/picker.sh"
  else
    tmux bind-key "$picker_key" run-shell -b "$SCRIPTS_DIR/picker.sh"
  fi
fi

# Cycle: prev/next between project sessions. Both keys must be set.
if [[ -n "$prev_key" && -n "$next_key" ]]; then
  if [[ "$cycle_no_prefix" == "on" ]]; then
    tmux bind-key -n "$prev_key" run-shell -b "$SCRIPTS_DIR/cycle.sh prev"
    tmux bind-key -n "$next_key" run-shell -b "$SCRIPTS_DIR/cycle.sh next"
  else
    tmux bind-key "$prev_key" run-shell -b "$SCRIPTS_DIR/cycle.sh prev"
    tmux bind-key "$next_key" run-shell -b "$SCRIPTS_DIR/cycle.sh next"
  fi
fi

# Carousel: cycles claude → editor → last-shell within the current project.
if [[ -n "$carousel_key" ]]; then
  if [[ "$carousel_no_prefix" == "on" ]]; then
    tmux bind-key -n "$carousel_key" run-shell -b "$SCRIPTS_DIR/carousel.sh"
  else
    tmux bind-key "$carousel_key" run-shell -b "$SCRIPTS_DIR/carousel.sh"
  fi
fi

# Dashboard: fzf overview of every Claude + OpenCode session across projects.
if [[ -n "$dashboard_key" ]]; then
  if [[ "$dashboard_no_prefix" == "on" ]]; then
    tmux bind-key -n "$dashboard_key" run-shell -b "$SCRIPTS_DIR/dashboard.sh"
  else
    tmux bind-key "$dashboard_key" run-shell -b "$SCRIPTS_DIR/dashboard.sh"
  fi
fi

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
