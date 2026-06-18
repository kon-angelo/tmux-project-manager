#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# tmux-project-manager — TPM entry point
# Manages project sessions with a unified picker, repair, and cycling.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# --- Option defaults ---
# Picker: M-p as a no-prefix global key. 'p' is a plain letter so Alt+p does
# not collide with any escape-sequence prefix and works reliably across
# Ghostty / iTerm / Alacritty / kitty / Linux terminals.
#
# Cycle: prefix-based by default — bound to prefix+{ / prefix+}. We
# previously tried:
#   - bare M-[/M-] (CSI/OSC prefixes; terminals intercept them)
#   - M-{/M-} (Alt+Shift+symbol; Ghostty/macOS handle inconsistently)
#   - prefix+[/prefix+] (works, but shadows tmux defaults copy-mode and
#     paste-buffer; bad for portability with stock tmux)
# prefix+{ / prefix+} shadow swap-pane -U/-D, but those have built-in
# alternatives (prefix+<>, plus most users no-prefix Alt+HJKL), so the
# collision is benign. Override via @tpm-prev-key / @tpm-next-key plus
# @tpm-cycle-no-prefix for no-prefix global cycling.
default_projects_file="$HOME/.config/projects/projects.yaml"
default_tool="opencode"
default_editor="nvim"
default_picker_key="M-p"
default_picker_no_prefix="on"
default_prev_key="{"
default_next_key="}"
default_cycle_no_prefix="off"
default_carousel_key="M-g"
default_carousel_no_prefix="on"

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

# --- Export config for scripts ---
tmux set-environment -g TPM_PROJECTS_FILE "$projects_file"
tmux set-environment -g TPM_DEFAULT_TOOL "$(get_opt "@tpm-default-tool" "$default_tool")"
tmux set-environment -g TPM_DEFAULT_EDITOR "$(get_opt "@tpm-default-editor" "$default_editor")"
tmux set-environment -g TPM_SCRIPTS_DIR "$SCRIPTS_DIR"

# --- Bind keys ---
# Picker: -n means root key table (no prefix). On by default.
if [[ "$picker_no_prefix" == "on" ]]; then
  tmux bind-key -n "$picker_key" run-shell -b "$SCRIPTS_DIR/picker.sh"
else
  tmux bind-key "$picker_key" run-shell -b "$SCRIPTS_DIR/picker.sh"
fi

# Cycle: prefix-based by default. Toggle with @tpm-cycle-no-prefix=on.
if [[ "$cycle_no_prefix" == "on" ]]; then
  tmux bind-key -n "$prev_key" run-shell -b "$SCRIPTS_DIR/cycle.sh prev"
  tmux bind-key -n "$next_key" run-shell -b "$SCRIPTS_DIR/cycle.sh next"
else
  tmux bind-key "$prev_key" run-shell -b "$SCRIPTS_DIR/cycle.sh prev"
  tmux bind-key "$next_key" run-shell -b "$SCRIPTS_DIR/cycle.sh next"
fi

# Carousel: cycles claude → editor → last-shell within the current project
# session. Defaults to no-prefix M-g.
if [[ "$carousel_no_prefix" == "on" ]]; then
  tmux bind-key -n "$carousel_key" run-shell -b "$SCRIPTS_DIR/carousel.sh"
else
  tmux bind-key "$carousel_key" run-shell -b "$SCRIPTS_DIR/carousel.sh"
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
