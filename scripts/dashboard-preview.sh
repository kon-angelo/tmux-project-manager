#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# dashboard-preview.sh — right-pane preview for the agent dashboard.
# Called by fzf on every cursor move. Must be fast (<50ms typical).
#
# Args: <agent> <session_id> <cwd>

set -uo pipefail  # not -e: preview must never fail the fzf loop

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

agent="${1:-}"
session_id="${2:-}"
cwd="${3:-}"

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[38;5;109m'
YELLOW=$'\033[38;5;179m'
RESET=$'\033[0m'

hdr() { printf '%s%s%s\n' "$BOLD" "$1" "$RESET"; }
kv()  { printf '%s%-10s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }

case "$agent" in
  claude)   hdr "${CYAN}claude${RESET}  ${DIM}${session_id}${RESET}" ;;
  opencode) hdr "${YELLOW}opencode${RESET}  ${DIM}${session_id}${RESET}" ;;
  *)        hdr "${agent:-?}  ${DIM}${session_id}${RESET}" ;;
esac
echo

if [[ -n "$cwd" ]]; then
  kv "cwd" "$cwd"
fi

# ─── Claude detail ──────────────────────────────────────────────────────────

claude_preview() {
  local history_file="$TPM_CLAUDE_DIR/history.jsonl"
  [[ -r "$history_file" ]] || return 0

  # Best-effort match against a live PID file for name/status.
  local sessions_dir="$TPM_CLAUDE_DIR/sessions"
  local pid_file pid meta name status updated
  if [[ -d "$sessions_dir" ]]; then
    shopt -s nullglob
    for pid_file in "$sessions_dir"/*.json; do
      pid="$(basename "$pid_file" .json)"
      [[ ! "$pid" =~ ^[0-9]+$ ]] && continue
      meta=$(cat "$pid_file" 2>/dev/null) || continue
      sid=$(printf '%s' "$meta" | jq -r '.sessionId // empty' 2>/dev/null)
      if [[ "$sid" == "$session_id" ]]; then
        name=$(printf '%s' "$meta" | jq -r '.name // empty' 2>/dev/null)
        status=$(printf '%s' "$meta" | jq -r '.status // empty' 2>/dev/null)
        updated=$(printf '%s' "$meta" | jq -r '.updatedAt // empty' 2>/dev/null)
        [[ -n "$name" ]]    && kv "name"    "$name"
        [[ -n "$status" ]]  && kv "status"  "$status"
        [[ -n "$updated" ]] && kv "updated" "$(tpm_ms_since "$updated") ago  (pid $pid)"
        break
      fi
    done
    shopt -u nullglob
  fi

  echo
  hdr "recent prompts"
  # Last 5 entries in history.jsonl for this session id, oldest first.
  jq -r --arg sid "$session_id" '
    select(.sessionId == $sid) |
    [(.timestamp | tostring), .display] | @tsv
  ' "$history_file" 2>/dev/null \
    | tail -5 \
    | awk -F'\t' '{
        # Truncate long prompts to ~200 chars for the preview pane.
        txt=$2
        if (length(txt) > 200) txt=substr(txt, 1, 199) "…"
        printf "  %s\n", txt
      }' \
    | sed 's/^/  /'
}

# ─── OpenCode detail ────────────────────────────────────────────────────────

opencode_preview() {
  [[ -r "$TPM_OPENCODE_DB" ]] || return 0

  # Session meta.
  # OpenCode session ids are alphanumeric (ses_<base62>) so no quoting
  # escape is needed; a plain string interpolation is safe.
  local q="SELECT
             coalesce(title,''),
             coalesce(agent,''),
             coalesce(model,''),
             cost,
             tokens_input, tokens_output, tokens_cache_read, tokens_cache_write,
             time_updated,
             coalesce(summary_files, 0),
             coalesce(summary_additions, 0),
             coalesce(summary_deletions, 0)
           FROM session WHERE id = '$session_id';"

  local title agent_field model cost ti to tcr tcw updated files adds dels
  IFS='|' read -r title agent_field model cost ti to tcr tcw updated files adds dels < <(
    sqlite3 -readonly "file:$TPM_OPENCODE_DB?mode=ro" "$q" 2>/dev/null
  )

  [[ -n "$title"       ]] && kv "title"   "$title"
  [[ -n "$agent_field" ]] && kv "agent"   "$agent_field"
  if [[ -n "$model" ]]; then
    # `model` is stored as either a plain string or a JSON object
    # `{"id":"...", "providerID":"..."}`. Extract the id when it's JSON.
    if [[ "$model" == \{* ]]; then
      model_id=$(printf '%s' "$model" | jq -r '.id // ""' 2>/dev/null)
      [[ -n "$model_id" ]] && model="$model_id"
    fi
    kv "model" "$model"
  fi
  [[ -n "$updated"     ]] && kv "updated" "$(tpm_ms_since "$updated") ago"
  if [[ -n "$cost" && "$cost" != "0" ]]; then
    kv "cost" "\$$cost"
  fi
  if [[ -n "$ti" ]]; then
    kv "tokens" "in=$ti out=$to cache=$tcr/$tcw"
  fi
  if [[ "$files" != "0" || "$adds" != "0" || "$dels" != "0" ]]; then
    kv "diff" "$files files  +$adds  -$dels"
  fi

  echo
  hdr "todos"
  sqlite3 -readonly "file:$TPM_OPENCODE_DB?mode=ro" \
    "SELECT status, content FROM todo WHERE session_id='$session_id' ORDER BY seq LIMIT 8;" \
    2>/dev/null \
    | awk -F'|' '
        {
          mark = "·"
          if ($1 == "completed") mark = "✓"
          else if ($1 == "in_progress") mark = "▸"
          else if ($1 == "pending") mark = "·"
          else if ($1 == "cancelled") mark = "✗"
          txt = $2
          if (length(txt) > 90) txt = substr(txt, 1, 89) "…"
          printf "  %s %s\n", mark, txt
        }'

  echo
  hdr "last prompt"
  # Newest user text part for this session. Use a single-line query rather
  # than a here-doc: the here-doc body would consume any pipe target placed
  # on the following line.
  local last_prompt
  last_prompt=$(sqlite3 -readonly "file:$TPM_OPENCODE_DB?mode=ro" \
    "SELECT json_extract(p.data, '\$.text')
     FROM part p JOIN message m ON m.id = p.message_id
     WHERE p.session_id = '$session_id'
       AND json_extract(m.data, '\$.role') = 'user'
       AND json_extract(p.data, '\$.type') = 'text'
     ORDER BY p.time_created DESC LIMIT 1;" 2>/dev/null)
  if [[ -n "$last_prompt" ]]; then
    if (( ${#last_prompt} > 400 )); then
      last_prompt="${last_prompt:0:399}…"
    fi
    printf '  %s\n' "$last_prompt"
  fi
}

case "$agent" in
  claude)   claude_preview   ;;
  opencode) opencode_preview ;;
esac
