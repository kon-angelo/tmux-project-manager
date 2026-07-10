#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# install.sh — Install the tmux-project-manager agent-status integrations.
#
# Detects which agents are installed (opencode, claude) and wires them up
# to publish status into tmux options so the tpm picker shows attention
# badges.
#
# Behaviour:
#   opencode plugin:
#     ~/.config/opencode/plugins/tpm-status.ts  →  <this-repo>/integrations/opencode-tpm-status.ts
#     (symlink; refuses to overwrite an existing non-symlink file)
#
#   Claude Code hook:
#     Adds entries in ~/.claude/settings.json under `hooks.<EventName>` that
#     call <this-repo>/integrations/claudecode-tpm-status.sh. Backs up the
#     existing settings.json first. Idempotent — re-running is a no-op.
#
# Flags:
#   --dry-run       Print what would happen; make no changes.
#   --uninstall     Remove the opencode symlink and the CC hook entries.
#   --only opencode|claudecode
#                   Restrict actions to one integration.
#   --scripts-dir <path>
#                   Override the source directory for the plugin files.
#                   Defaults to $(dirname "$0")/../integrations resolved.
#   -h, --help      This message.

set -euo pipefail

# --- Paths ---
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$INSTALL_DIR/.." && pwd)"
OPENCODE_PLUGIN_SRC="$INSTALL_DIR/opencode-tpm-status.ts"
CLAUDECODE_HOOK_SRC="$INSTALL_DIR/claudecode-tpm-status.sh"

OPENCODE_PLUGIN_DEST_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/plugins"
OPENCODE_PLUGIN_DEST="$OPENCODE_PLUGIN_DEST_DIR/tpm-status.ts"

CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Claude Code events we want to hook. Kept in sync with
# integrations/claudecode-tpm-status.sh.
CLAUDE_EVENTS=(
  SessionStart
  UserPromptSubmit
  Stop
  Notification
  PermissionRequest
  PostToolUseFailure
  SessionEnd
)

# --- Flags ---
DRY_RUN=0
UNINSTALL=0
ONLY=""

usage() {
  sed -n '1,/^set -euo pipefail/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//' | sed '/^$/d;/^set -euo/d'
}

while (($#)); do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --only)      ONLY="${2:-}"; shift 2 ;;
    --scripts-dir)
                 INSTALL_DIR="$(cd "$2" && pwd)"
                 OPENCODE_PLUGIN_SRC="$INSTALL_DIR/opencode-tpm-status.ts"
                 CLAUDECODE_HOOK_SRC="$INSTALL_DIR/claudecode-tpm-status.sh"
                 shift 2
                 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$ONLY" && "$ONLY" != "opencode" && "$ONLY" != "claudecode" ]]; then
  echo "Invalid --only value: $ONLY (want opencode or claudecode)" >&2
  exit 2
fi

# --- Logging helpers ---
log()      { printf '[install] %s\n' "$*"; }
info()     { printf '[install] \033[36m%s\033[0m\n' "$*"; }
ok()       { printf '[install] \033[32m✓\033[0m %s\n' "$*"; }
skip()     { printf '[install] \033[2m• %s\033[0m\n' "$*"; }
warn()     { printf '[install] \033[33m!\033[0m %s\n' "$*" >&2; }
err()      { printf '[install] \033[31m✗\033[0m %s\n' "$*" >&2; }

do_or_dry() {
  # Run a command, or (in dry-run) print what would run. Arguments are
  # passed through as-is; no shell interpolation. Callers should pass a
  # command and its argv exactly as they'd invoke it directly.
  if (( DRY_RUN )); then
    local quoted=""
    local a
    for a in "$@"; do
      quoted+=" $(printf '%q' "$a")"
    done
    printf '[install] \033[2m(dry-run)%s\033[0m\n' "$quoted"
  else
    "$@"
  fi
}

# ============================================================================
# OpenCode plugin
# ============================================================================

install_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    skip "opencode: binary not found on PATH, skipping"
    return 0
  fi
  if [[ ! -f "$OPENCODE_PLUGIN_SRC" ]]; then
    err "opencode: source plugin not found: $OPENCODE_PLUGIN_SRC"
    return 1
  fi

  info "opencode: detected"

  # Create the plugins directory if missing.
  if [[ ! -d "$OPENCODE_PLUGIN_DEST_DIR" ]]; then
    do_or_dry mkdir -p "$OPENCODE_PLUGIN_DEST_DIR"
  fi

  # Check the destination.
  if [[ -L "$OPENCODE_PLUGIN_DEST" ]]; then
    local target
    target=$(readlink "$OPENCODE_PLUGIN_DEST")
    if [[ "$target" == "$OPENCODE_PLUGIN_SRC" ]]; then
      skip "opencode: plugin already installed (symlink up to date)"
      return 0
    fi
    warn "opencode: existing symlink points to a different target: $target"
    do_or_dry ln -sf "$OPENCODE_PLUGIN_SRC" "$OPENCODE_PLUGIN_DEST"
    (( DRY_RUN )) || ok "opencode: symlink updated"
    return 0
  fi

  if [[ -e "$OPENCODE_PLUGIN_DEST" ]]; then
    err "opencode: $OPENCODE_PLUGIN_DEST exists and is not a symlink; refusing to overwrite"
    err "        move it aside and re-run, or install manually"
    return 1
  fi

  do_or_dry ln -s "$OPENCODE_PLUGIN_SRC" "$OPENCODE_PLUGIN_DEST"
  (( DRY_RUN )) || ok "opencode: plugin symlinked -> $OPENCODE_PLUGIN_DEST"
}

uninstall_opencode() {
  if [[ -L "$OPENCODE_PLUGIN_DEST" ]]; then
    local target
    target=$(readlink "$OPENCODE_PLUGIN_DEST")
    if [[ "$target" == "$OPENCODE_PLUGIN_SRC" ]]; then
      do_or_dry rm "$OPENCODE_PLUGIN_DEST"
      (( DRY_RUN )) || ok "opencode: symlink removed"
      return 0
    fi
    skip "opencode: symlink points elsewhere ($target), leaving alone"
    return 0
  fi
  skip "opencode: no plugin symlink to remove"
}

# ============================================================================
# Claude Code hook
# ============================================================================

# Claude Code identification: the `claude` CLI or the settings file.
detect_claude() {
  if command -v claude >/dev/null 2>&1; then return 0; fi
  if [[ -f "$CLAUDE_SETTINGS" ]]; then return 0; fi
  # Broken symlink counts as "user is trying to use CC but has a broken setup".
  if [[ -L "$CLAUDE_SETTINGS" ]]; then return 0; fi
  return 1
}

# Resolve the actual settings.json path (following symlinks). Creates the
# target if the symlink is dangling. Prints the resolved absolute path.
resolve_claude_settings() {
  local p="$CLAUDE_SETTINGS"
  if [[ -L "$p" ]]; then
    local target
    target=$(readlink "$p")
    # Make target absolute if relative.
    case "$target" in
      /*) ;;
       *) target="$(dirname "$p")/$target" ;;
    esac
    printf '%s\n' "$target"
    return 0
  fi
  printf '%s\n' "$p"
}

install_claudecode() {
  if ! detect_claude; then
    skip "claudecode: claude CLI not found and no settings file, skipping"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    err "claudecode: jq is required to safely edit settings.json"
    err "           install jq (brew install jq) and re-run"
    return 1
  fi
  if [[ ! -x "$CLAUDECODE_HOOK_SRC" ]]; then
    err "claudecode: hook script not executable: $CLAUDECODE_HOOK_SRC"
    return 1
  fi

  info "claudecode: detected"

  local settings_path
  settings_path=$(resolve_claude_settings)

  # Ensure parent dir exists.
  local settings_dir
  settings_dir=$(dirname "$settings_path")
  if [[ ! -d "$settings_dir" ]]; then
    do_or_dry mkdir -p "$settings_dir"
  fi

  # Seed an empty settings file if none exists (broken symlink or missing).
  if [[ ! -f "$settings_path" ]]; then
    warn "claudecode: settings file missing at $settings_path — creating minimal file"
    if (( DRY_RUN )); then
      printf '[install] \033[2m(dry-run) would create %s with {"hooks": {}}\033[0m\n' "$settings_path"
      for ev in "${CLAUDE_EVENTS[@]}"; do
        printf '[install] \033[2m(dry-run) would add hook for %s\033[0m\n' "$ev"
      done
      return 0
    else
      printf '{\n  "hooks": {}\n}\n' > "$settings_path"
    fi
  fi

  # Build a JSON expression that, for each event we want to hook, appends
  # an entry pointing at our script — but only if no entry with our command
  # is already present under that event. Idempotent.
  local cmd="$CLAUDECODE_HOOK_SRC"
  local ts
  ts=$(date +%s)

  # Emit an events JSON array for jq.
  local events_json
  events_json=$(printf '%s\n' "${CLAUDE_EVENTS[@]}" | jq -R . | jq -s -c .)

  local jq_program
  jq_program=$(cat <<'JQ'
    . as $root
    | ($events | fromjson) as $events
    | reduce $events[] as $ev (
        $root;
        .hooks //= {} |
        .hooks[$ev] //= [] |
        if any(.hooks[$ev][]?; .hooks // [] | any(.command == $cmd))
        then .
        else
          .hooks[$ev] += [{
            matcher: "",
            hooks: [{
              type: "command",
              command: $cmd,
              timeout: 5,
              async: true
            }]
          }]
        end
      )
JQ
  )

  # Dry-run: show a diff-ish preview instead of writing.
  if (( DRY_RUN )); then
    local preview
    preview=$(jq --arg events "$events_json" --arg cmd "$cmd" "$jq_program" "$settings_path")
    # Report which events would be added.
    local ev
    for ev in "${CLAUDE_EVENTS[@]}"; do
      local present existing
      present=$(printf '%s' "$preview" | jq -r --arg ev "$ev" --arg cmd "$cmd" \
        '.hooks[$ev] // [] | map(.hooks[]? | select(.command == $cmd)) | length')
      existing=$(jq -r --arg ev "$ev" --arg cmd "$cmd" \
        '.hooks[$ev] // [] | map(.hooks[]? | select(.command == $cmd)) | length' \
        "$settings_path")
      if (( present > existing )); then
        printf '[install] \033[2m(dry-run) would add hook for %s\033[0m\n' "$ev"
      else
        skip "claudecode: hook already present for $ev"
      fi
    done
    return 0
  fi

  # Backup.
  local backup="$settings_path.tpm-install.$ts.bak"
  cp "$settings_path" "$backup"

  # Compute the new content and check whether anything changed.
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2016
  jq --arg events "$events_json" --arg cmd "$cmd" "$jq_program" "$settings_path" > "$tmp"

  if diff -q "$settings_path" "$tmp" >/dev/null 2>&1; then
    skip "claudecode: settings.json already contains all required hooks"
    rm -f "$tmp" "$backup"
    return 0
  fi

  mv "$tmp" "$settings_path"
  ok "claudecode: settings.json updated (backup: $backup)"
  for ev in "${CLAUDE_EVENTS[@]}"; do
    local count
    count=$(jq -r --arg ev "$ev" --arg cmd "$cmd" \
      '.hooks[$ev] // [] | map(.hooks[]? | select(.command == $cmd)) | length' \
      "$settings_path")
    if (( count > 0 )); then
      printf '[install]   \033[32m+\033[0m %s\n' "$ev"
    fi
  done
}

uninstall_claudecode() {
  if [[ ! -f "$CLAUDE_SETTINGS" && ! -L "$CLAUDE_SETTINGS" ]]; then
    skip "claudecode: no settings file, nothing to uninstall"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    err "claudecode: jq required for uninstall"
    return 1
  fi

  local settings_path
  settings_path=$(resolve_claude_settings)
  if [[ ! -f "$settings_path" ]]; then
    skip "claudecode: settings file not found at $settings_path"
    return 0
  fi

  local cmd="$CLAUDECODE_HOOK_SRC"
  local ts
  ts=$(date +%s)

  # Remove entries whose inner hooks[] mention our command. If that empties
  # an event array, drop the event key.
  local jq_program
  jq_program=$(cat <<'JQ'
    .hooks //= {} |
    .hooks |= with_entries(
      .value |= map(
        select(
          (.hooks // [] | any(.command == $cmd)) | not
        )
      )
    ) |
    .hooks |= with_entries(select(.value | length > 0))
JQ
  )

  local tmp
  tmp=$(mktemp)
  jq --arg cmd "$cmd" "$jq_program" "$settings_path" > "$tmp"

  if diff -q "$settings_path" "$tmp" >/dev/null 2>&1; then
    skip "claudecode: no hooks pointing at our script"
    rm -f "$tmp"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '[install] \033[2m(dry-run) would remove tpm hooks from %s\033[0m\n' "$settings_path"
    rm -f "$tmp"
    return 0
  fi

  local backup="$settings_path.tpm-uninstall.$ts.bak"
  cp "$settings_path" "$backup"
  mv "$tmp" "$settings_path"
  ok "claudecode: hooks removed (backup: $backup)"
}

# ============================================================================
# Driver
# ============================================================================

main() {
  info "tmux-project-manager agent-status installer"
  info "  repo:     $REPO_DIR"
  info "  scripts:  $INSTALL_DIR"
  if (( DRY_RUN )); then info "  mode:     DRY RUN (no changes)"; fi

  local rc=0
  if (( UNINSTALL )); then
    [[ -z "$ONLY" || "$ONLY" == "opencode"   ]] && { uninstall_opencode   || rc=$?; }
    [[ -z "$ONLY" || "$ONLY" == "claudecode" ]] && { uninstall_claudecode || rc=$?; }
  else
    [[ -z "$ONLY" || "$ONLY" == "opencode"   ]] && { install_opencode   || rc=$?; }
    [[ -z "$ONLY" || "$ONLY" == "claudecode" ]] && { install_claudecode || rc=$?; }
  fi

  if (( rc == 0 )); then
    if (( DRY_RUN )); then
      info "dry-run complete"
    elif (( UNINSTALL )); then
      info "uninstall complete"
    else
      info "install complete"
      info ""
      info "next steps:"
      info "  • restart running opencode/claude sessions to pick up the plugin/hook"
      info "  • open the tpm picker (M-p) — projects with active agents will show a badge"
    fi
  else
    err "one or more integrations failed (rc=$rc)"
  fi
  return $rc
}

main "$@"
