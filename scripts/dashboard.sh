#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Konstantinos Angelopoulos
#
# dashboard.sh — fzf overview of every Claude + OpenCode session across
# registered projects. Invoked by @tpm-dashboard-key (default M-o).
#
# Row = one agent session. Sources:
#   Claude live      — ~/.claude/sessions/<PID>.json + `kill -0 <PID>`
#   Claude detached  — ~/.claude/history.jsonl, grouped by sessionId
#   OpenCode         — ~/.local/share/opencode/opencode.db (WAL, safe reads)
#   Status overlay   — @tpm-agent-status-<source>-<id> tmux options
#   Tmux mapping     — tmux list-panes -a + pgrep -P for child processes
#
# Rows are filtered to projects registered in projects.yaml. Sort order:
# state priority desc (needs-input > error > done > working > ready > idle),
# then age asc.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATIONS_DIR="$(cd "$CURRENT_DIR/../integrations" && pwd)"
# shellcheck source=utils.sh
source "$CURRENT_DIR/utils.sh"

# The dashboard is a tmux-native UI: it opens a popup, reads session options,
# and dispatches switch-client. Running it outside a tmux session produces
# cryptic failures — guard early with a clear message.
if ! tmux info >/dev/null 2>&1; then
  echo "tpm: dashboard must be invoked from inside a tmux session" >&2
  exit 1
fi

if ! validate_projects_file; then
  tmux display-message "tpm: invalid projects file (see stderr)"
  exit 1
fi

load_projects_cache
load_session_cache

result_file="${TPM_STATE_PREFIX}-dashboard-result"
list_file="${TPM_STATE_PREFIX}-dashboard-list"
NOW_MS=$(tpm_now_ms)
CUTOFF_MS=$(( NOW_MS - TPM_DASHBOARD_CUTOFF_DAYS * 86400 * 1000 ))

# ─── Phase 1 ── build the tmux/process index ────────────────────────────────

declare -A PANE_BY_PID          # pid -> "tmux_session|win.pane"
declare -A PANE_CWD_BY_PID      # pid -> cwd
declare -A PANE_CMD_BY_PID      # pid -> current pane command
declare -A TMUX_STATUS          # "agent|session_id" -> state
declare -A TMUX_STATUS_SESSION  # "agent|session_id" -> tmux_session hosting the option

while IFS='|' read -r sess loc ppid cmd cpath children; do
  [[ -z "$ppid" ]] && continue
  PANE_BY_PID["$ppid"]="$sess|$loc"
  PANE_CWD_BY_PID["$ppid"]="$cpath"
  PANE_CMD_BY_PID["$ppid"]="$cmd"
  for child in $children; do
    [[ -z "$child" ]] && continue
    PANE_BY_PID["$child"]="$sess|$loc"
    PANE_CWD_BY_PID["$child"]="$cpath"
  done
done < <(list_agent_panes)

# Enumerate @tpm-agent-status-* options across every tmux session (managed or
# not — the adapter may have written options to a session before it was
# marked managed).
if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  while IFS= read -r sess; do
    [[ -z "$sess" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%% *}"
      value="${line#* }"
      value="${value#\"}"; value="${value%\"}"
      rest="${name#${TPM_AGENT_STATUS_PREFIX}}"
      case "$rest" in
        opencode-*)    agent="opencode";   id="${rest#opencode-}"   ;;
        claudecode-*)  agent="claudecode"; id="${rest#claudecode-}" ;;
        *) continue ;;
      esac
      TMUX_STATUS["$agent|$id"]="$value"
      TMUX_STATUS_SESSION["$agent|$id"]="$sess"
    done < <(list_agent_status_sources "$sess")
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
fi

# ─── Phase 2 ── emit rows ───────────────────────────────────────────────────
#
# emit_row prints a single TSV line. Field order (12 columns):
#
#   1  state       needs-input|error|done|working|ready|idle
#   2  agent       claude|opencode
#   3  session_id
#   4  project_key
#   5  cwd
#   6  title
#   7  tmux_session_name  (or "-")
#   8  tmux_loc           (e.g. "main:1.1", or "-")
#   9  age_ms             (epoch ms of last update — used for sorting)
#  10  pid                (int or "-")
#  11  flag               (live|detached)
#  12  display            (ANSI-colored visible content — set later)
#
# The `display` field is filled in by render_rows after sorting.

emit_row() {
  # positional: state, agent, session_id, project_key, cwd, title,
  #             tmux_session_name, tmux_loc, age_ms, pid, flag
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

# Sanitize a string for TSV: strip tabs, newlines, and control chars.
sanitize() {
  printf '%s' "$1" | tr -d '\t\n\r' | head -c 200
}

# ─── Claude live ────────────────────────────────────────────────────────────

declare -A CLAUDE_LIVE_SEEN  # session_id -> 1 (dedup live vs detached)

collect_claude_live() {
  local sessions_dir="$TPM_CLAUDE_DIR/sessions"
  [[ -d "$sessions_dir" ]] || return 0

  local pid_file pid meta sess_id cwd title status updated project_key
  local tmux_state tmux_sess pane state loc

  shopt -s nullglob
  for pid_file in "$sessions_dir"/*.json; do
    pid="$(basename "$pid_file" .json)"
    [[ ! "$pid" =~ ^[0-9]+$ ]] && continue
    kill -0 "$pid" 2>/dev/null || continue

    meta=$(cat "$pid_file" 2>/dev/null) || continue
    sess_id=$(printf '%s' "$meta" | jq -r '.sessionId // empty' 2>/dev/null)
    [[ -z "$sess_id" ]] && continue
    cwd=$(printf '%s' "$meta" | jq -r '.cwd // empty' 2>/dev/null)
    title=$(printf '%s' "$meta" | jq -r '.name // "(claude)"' 2>/dev/null)
    status=$(printf '%s' "$meta" | jq -r '.status // "unknown"' 2>/dev/null)
    updated=$(printf '%s' "$meta" | jq -r '.updatedAt // .startedAt // 0' 2>/dev/null)

    project_key=$(detect_current_project "$cwd")
    [[ -z "$project_key" ]] && continue

    tmux_state="${TMUX_STATUS[claudecode|$sess_id]:-}"
    tmux_sess="${TMUX_STATUS_SESSION[claudecode|$sess_id]:-}"
    pane="${PANE_BY_PID[$pid]:-}"

    # State: prefer tmux option (semantic), fall back to claude's busy/idle.
    if [[ -n "$tmux_state" ]]; then
      state="$tmux_state"
    else
      case "$status" in
        busy) state="working" ;;
        idle) state="idle" ;;
        *)    state="idle" ;;
      esac
    fi

    # tmux location from pane index.
    if [[ -n "$pane" ]]; then
      loc="${pane#*|}"
      tmux_sess="${tmux_sess:-${pane%|*}}"
    else
      loc="-"
      tmux_sess="${tmux_sess:--}"
    fi

    CLAUDE_LIVE_SEEN["$sess_id"]=1
    emit_row \
      "$state" "claude" "$sess_id" "$project_key" "$cwd" "$(sanitize "$title")" \
      "$tmux_sess" "$loc" "$updated" "$pid" "live"
  done
  shopt -u nullglob
}

# ─── Claude detached ────────────────────────────────────────────────────────
#
# ~/.claude/history.jsonl is the authoritative source for "which sessions has
# the user actually typed into." We fold it by sessionId, keeping the most
# recent entry per session (the row we surface as the "last prompt").
#
# JSONL files under ~/.claude/projects/*/*.jsonl exist for many sessions that
# never appeared in history.jsonl (agent-only turns, or older sessions where
# history.jsonl was rotated). We deliberately skip those — the value of the
# dashboard is "sessions I recently interacted with", not "every transcript
# on disk". This is the fix for the PoC's noisy JSONL scan.

collect_claude_detached() {
  local history_file="$TPM_CLAUDE_DIR/history.jsonl"
  [[ -r "$history_file" ]] || return 0

  # Fold history.jsonl by sessionId, keeping the max-timestamp entry per id.
  # jq groups then reduces to the single latest entry, emitting TSV.
  local line sess_id cwd title ts project_key tmux_state tmux_sess state
  while IFS=$'\t' read -r sess_id ts cwd title; do
    [[ -z "$sess_id" ]] && continue
    [[ -n "${CLAUDE_LIVE_SEEN[$sess_id]:-}" ]] && continue
    (( ts >= CUTOFF_MS )) || continue

    project_key=$(detect_current_project "$cwd")
    [[ -z "$project_key" ]] && continue

    tmux_state="${TMUX_STATUS[claudecode|$sess_id]:-}"
    tmux_sess="${TMUX_STATUS_SESSION[claudecode|$sess_id]:-}"
    if [[ -n "$tmux_state" ]]; then
      state="$tmux_state"
    else
      state="idle"
    fi

    emit_row \
      "$state" "claude" "$sess_id" "$project_key" "$cwd" "$(sanitize "$title")" \
      "${tmux_sess:--}" "-" "$ts" "-" "detached"
  done < <(
    jq -r '
      [.sessionId, (.timestamp | tostring), .project, .display] | @tsv
    ' "$history_file" 2>/dev/null \
    | awk -F'\t' '
      # For each sessionId, keep the row with the largest timestamp.
      { if (!(($1) in maxt) || ($2)+0 > maxt[$1]+0) { maxt[$1]=$2; row[$1]=$0 } }
      END { for (k in row) print row[k] }
    '
  )
}

# ─── OpenCode ───────────────────────────────────────────────────────────────
#
# One row per session record in opencode.db whose time_updated is within the
# cutoff. Live-vs-detached is decided by the presence of a per-source tmux
# option. We deliberately do NOT infer live-ness from process/cwd matching
# in v1: the plan settled on tmux-options-as-authoritative; the alternative
# heuristic ("most recent session in a matching cwd") caused the PoC's
# "candidate" over-attribution.

collect_opencode() {
  [[ -r "$TPM_OPENCODE_DB" ]] || return 0

  local sql="SELECT id, coalesce(directory,''), coalesce(title,'(untitled)'), time_updated
             FROM session
             WHERE (time_archived IS NULL OR time_archived = 0)
               AND time_updated >= $CUTOFF_MS
             ORDER BY time_updated DESC;"

  local sid sdir stitle supdated project_key
  local tmux_state tmux_sess state flag loc pid_out
  while IFS='|' read -r sid sdir stitle supdated; do
    [[ -z "$sid" ]] && continue
    project_key=$(detect_current_project "$sdir")
    [[ -z "$project_key" ]] && continue

    tmux_state="${TMUX_STATUS[opencode|$sid]:-}"
    tmux_sess="${TMUX_STATUS_SESSION[opencode|$sid]:-}"

    if [[ -n "$tmux_state" ]]; then
      state="$tmux_state"
      flag="live"
      # Locate a pane: any pane in tmux_sess with pane_current_command opencode*
      loc="-"
      pid_out="-"
      if [[ -n "$tmux_sess" ]]; then
        while IFS='|' read -r pid win_pane cmd; do
          if [[ "$cmd" == opencode* ]]; then
            loc="$win_pane"
            pid_out="$pid"
            break
          fi
        done < <(
          tmux list-panes -t "=$tmux_sess" \
            -F '#{pane_pid}|#{window_index}.#{pane_index}|#{pane_current_command}' \
            2>/dev/null || true
        )
      fi
    else
      state="idle"
      flag="detached"
      tmux_sess="-"
      loc="-"
      pid_out="-"
    fi

    emit_row \
      "$state" "opencode" "$sid" "$project_key" "$sdir" "$(sanitize "$stitle")" \
      "${tmux_sess:--}" "$loc" "$supdated" "$pid_out" "$flag"
  done < <(sqlite3 -readonly "file:$TPM_OPENCODE_DB?mode=ro" "$sql" 2>/dev/null || true)
}

# ─── Phase 3 ── sort + render ───────────────────────────────────────────────

# Numeric state priority for sort: higher wins.
state_priority() {
  case "$1" in
    needs-input) echo 5 ;;
    error)       echo 4 ;;
    done)        echo 3 ;;
    working)     echo 2 ;;
    ready)       echo 1 ;;
    idle)        echo 0 ;;
    *)           echo 0 ;;
  esac
}

# Convert raw TSV rows to render-ready rows with a leading sort prefix and
# an ANSI-colored display column appended as the last field.
#
# Sort prefix: "<priority>\t<neg_age_ms>" — priority desc first, then most
# recent age first within a state (invert the epoch so `sort -n` gives
# newest-first).

render_rows() {
  local BADGE_NEEDS=$'\033[1;38;5;179m'
  local BADGE_ERROR=$'\033[1;38;5;167m'
  local BADGE_DONE=$'\033[38;5;108m'
  local BADGE_WORKING=$'\033[38;5;110m'    # nord9 blue — same convention as picker
  local DIM=$'\033[2;38;5;240m'
  local AGENT_CLAUDE=$'\033[38;5;109m'     # nord8 cyan-ish
  local AGENT_OPENCODE=$'\033[38;5;179m'   # nord13 yellow-ish
  local DETACHED=$'\033[2;38;5;244m'
  local RESET=$'\033[0m'

  local state agent sess_id project_key cwd title tmux_sess loc age_ms pid flag
  local prio badge agent_col agent_char body age_hr loc_display display

  while IFS=$'\t' read -r state agent sess_id project_key cwd title \
                          tmux_sess loc age_ms pid flag; do
    [[ -z "$state" ]] && continue
    prio=$(state_priority "$state")

    case "$state" in
      needs-input) badge="${BADGE_NEEDS}! ${RESET}" ;;
      error)       badge="${BADGE_ERROR}x ${RESET}" ;;
      done)        badge="${BADGE_DONE}● ${RESET}" ;;
      working)     badge="${BADGE_WORKING}~ ${RESET}" ;;
      *)           badge="  " ;;
    esac

    case "$agent" in
      claude)   agent_col="$AGENT_CLAUDE";   agent_char="c" ;;
      opencode) agent_col="$AGENT_OPENCODE"; agent_char="o" ;;
      *)        agent_col=""; agent_char="?" ;;
    esac

    age_hr=$(tpm_ms_since "$age_ms")

    if [[ "$flag" == "detached" ]]; then
      # OpenCode detached rows can't be automatically resumed to the exact
      # session (see docs/dashboard-future-work.md) — the ↪ prefix cues that
      # the user must manually attach if they want to interact with this
      # specific session, in addition to whatever state badge shows.
      # Claude detached rows are auto-resumed by claudecode-tpm-resume.sh via
      # `claude --resume`, so no attach hint is needed there.
      if [[ "$agent" == "opencode" ]]; then
        loc_display="↪ detached"
      else
        loc_display="detached"
      fi
    elif [[ "$loc" == "-" || -z "$loc" ]]; then
      loc_display="live"
    else
      loc_display="${tmux_sess}:${loc}"
    fi

    # Truncate title to keep the display line predictable.
    local title_short="$title"
    if (( ${#title_short} > 48 )); then
      title_short="${title_short:0:47}…"
    fi

    printf -v body '%s%s%s %-14s %-48s' \
      "$agent_col" "$agent_char" "$RESET" "$project_key" "$title_short"

    if [[ "$flag" == "detached" ]]; then
      display="${badge}${DETACHED}${body} ${loc_display} ${age_hr}${RESET}"
    else
      display="${badge}${body} ${DIM}${loc_display} ${age_hr}${RESET}"
    fi

    # Sort prefix: priority desc (invert), then age desc (larger age_ms wins).
    # Format has 14 specifiers to match 14 args: 2 numeric + 12 string fields
    # (state, agent, sess_id, project_key, cwd, title, tmux_sess, loc,
    # age_ms, pid, flag, display).
    printf '%02d\t%020d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$((99 - prio))" "$((99999999999999 - age_ms))" \
      "$state" "$agent" "$sess_id" "$project_key" "$cwd" "$title" \
      "$tmux_sess" "$loc" "$age_ms" "$pid" "$flag" "$display" \
      || true
  done
}

# ─── Assemble list ──────────────────────────────────────────────────────────
#
# Wrapped in a function so the fzf popup can invoke this script recursively
# with `--list` to regenerate the row set on reload (ctrl-r, or post-ack).
# All source enumeration happens per call — cheap enough to run on every
# reload (SQLite reads are indexed; ~/.claude fs walks are bounded).

emit_rows() {
  {
    collect_claude_live
    collect_claude_detached
    collect_opencode
  } | render_rows | sort -t$'\t' -k1,1 -k2,2 -s | cut -f3-
}

# ─── Subcommand dispatch ────────────────────────────────────────────────────
#
# Runs after all functions and phase-1 index-building have completed so both
# --list and --ack see the same tmux/process state the popup dispatch would.
#
#   --list                          emit fresh rows to stdout; used as fzf's
#                                   initial input and its reload command.
#   --ack <agent> <sess_id> <sess>  clear the row's `done` marker if any and
#                                   emit a tmux notice. No-op if not `done`.

case "${1:-}" in
  --list)
    emit_rows
    exit 0
    ;;
  --ack)
    _agent="${2:-}"
    _sess_id="${3:-}"
    _tmux_sess="${4:-}"
    if [[ -z "$_tmux_sess" || "$_tmux_sess" == "-" ]]; then
      tmux display-message "tpm: no tmux session to acknowledge for this row"
      exit 0
    fi
    case "$_agent" in
      claude)   _src="claudecode" ;;
      opencode) _src="opencode"   ;;
      *)        _src="$_agent"    ;;
    esac
    if acknowledge_agent_source "$_tmux_sess" "$_src" "$_sess_id"; then
      tmux display-message "tpm: ack'd $_agent session (${_sess_id:0:12}…)"
    else
      tmux display-message "tpm: row not in 'done' state"
    fi
    exit 0
    ;;
esac

# ─── Normal (interactive) flow ──────────────────────────────────────────────

emit_rows > "$list_file"

if [[ ! -s "$list_file" ]]; then
  tmux display-message "tpm: dashboard: no agent sessions in the last ${TPM_DASHBOARD_CUTOFF_DAYS}d"
  exit 0
fi

# ─── fzf UI ─────────────────────────────────────────────────────────────────

header="Agent sessions [${TPM_DASHBOARD_CUTOFF_DAYS}d]  enter:jump  ^r:refresh  ^a:ack-done  esc:close"

rm -f "$result_file"

# ctrl-r and ctrl-a are handled inside the fzf loop via `reload` — the popup
# stays open, only the row set updates. Only enter (empty --expect) closes
# the popup and hands off to the post-fzf dispatch.
#
# ctrl-a passes {2}={agent} {3}={session_id} {7}={tmux_sess} to --ack; those
# indexes match the TSV column order emitted by emit_rows.
tmux display-popup -w 95% -h 85% -E "
  cat '$list_file' | \
  fzf \
    --ansi \
    --height=100% \
    --header='$header' \
    --delimiter=\$'\t' \
    --with-nth=12 \
    --pointer='▶' \
    --marker='●' \
    --color='pointer:green,fg+:green,bg+:-1' \
    --preview='$CURRENT_DIR/dashboard-preview.sh {2} {3} {5}' \
    --preview-window='right:50%:wrap' \
    --bind='ctrl-r:reload($CURRENT_DIR/dashboard.sh --list)+refresh-preview' \
    --bind='ctrl-a:execute-silent($CURRENT_DIR/dashboard.sh --ack {2} {3} {7})+reload($CURRENT_DIR/dashboard.sh --list)+refresh-preview' \
    --no-sort \
    --reverse \
    > '$result_file'
" 2>/dev/null || true

[[ ! -s "$result_file" ]] && exit 0
selected_line=$(<"$result_file")
rm -f "$result_file"
[[ -z "$selected_line" ]] && exit 0

# Extract row fields.
IFS=$'\t' read -r r_state r_agent r_sess_id r_project_key r_cwd r_title \
                  r_tmux_sess r_loc r_age r_pid r_flag _rest \
                  <<< "$selected_line"

# ─── Dispatch (enter only) ──────────────────────────────────────────────────
#
# ctrl-r and ctrl-a never reach here anymore — they're handled inside fzf.
# The only reason we're past the popup is that the user pressed enter on a
# row (or hit esc, which is filtered above by the empty-file check).

if [[ "$r_flag" == "live" ]]; then
  # Jump to the pane hosting this agent.
  if [[ -n "$r_tmux_sess" && "$r_tmux_sess" != "-" ]]; then
    tmux switch-client -t "=$r_tmux_sess"
    # Try the pane-derived window index first. Precise when the agent PID
    # is reachable via `pgrep -P` from the pane's shell (direct child);
    # it comes up short when the agent is nested deeper in the process
    # tree or when the pane mapping is stale.
    _switched_window=0
    if [[ -n "$r_loc" && "$r_loc" != "-" ]]; then
      # r_loc is "win.pane" — select-window by index is enough; the
      # in-window pane is left as-is (usual convention for agent panes).
      if tmux select-window -t "=${r_tmux_sess}:${r_loc%.*}" 2>/dev/null; then
        _switched_window=1
      fi
    fi
    # Fallback: select the managed tool window by name. Every tpm-launched
    # session has a window named "$TPM_WINDOW_TOOL" hosting the agent, so
    # this is a reliable landing spot when the PID→pane map came up short.
    if [[ "$_switched_window" -eq 0 ]]; then
      tmux select-window -t "=${r_tmux_sess}:${TPM_WINDOW_TOOL}" 2>/dev/null || true
    fi
  else
    tmux display-message "tpm: live row has no tmux location; refresh?"
  fi
else
  # Detached row: dispatch to the per-agent resume hook.
  case "$r_agent" in
    claude)   hook="$INTEGRATIONS_DIR/claudecode-tpm-resume.sh" ;;
    opencode) hook="$INTEGRATIONS_DIR/opencode-tpm-resume.sh"   ;;
    *)        hook="" ;;
  esac
  if [[ -z "$hook" || ! -x "$hook" ]]; then
    tmux display-message "tpm: dashboard: resume hook missing for '$r_agent'"
    exit 1
  fi
  TPM_WINDOW_TOOL="$TPM_WINDOW_TOOL" TPM_WINDOW_EDITOR="$TPM_WINDOW_EDITOR" \
    "$hook" "$r_sess_id" "$r_project_key" "$r_cwd" "$r_tmux_sess" \
    || tmux display-message "tpm: resume hook '$r_agent' failed (see stderr)"
fi
