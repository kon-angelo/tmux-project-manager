# Dashboard (`M-o`)

An fzf overview of every Claude Code and OpenCode session across the projects
you have registered in `projects.yaml`, live or detached, with real-time
status. Complementary to the picker (`M-p`):

| Feature       | Picker (`M-p`)                | Dashboard (`M-o`)                  |
|---------------|-------------------------------|------------------------------------|
| Unit          | One row per project           | One row per **agent session**      |
| Live signal   | Aggregated agent status       | Per-session state + tmux location  |
| Sources       | `projects.yaml` + tmux options| Claude JSON + OpenCode DB + tmux   |
| History       | No                            | Detached sessions from last 7d     |
| Default key   | `M-p`                         | `M-o`                              |

## Row schema

Every visible row corresponds to a single agent session. Columns from left
to right:

```
STATE  AGENT  PROJECT           TITLE                        LOCATION      AGE
!      o      dotfiles          Claude sessions fzf dashb…   dot:1.1       8s
~      o      dod-logs          View Git remote URL          dodlogs:1.1   5s
       o      gardener-…-aws    AWS NLB managed SG           detached      14h
       c      urchin-zmk-firm…  make a recap                 detached      14h
```

- **STATE badge** (leftmost, 2 columns) — mirrors the picker's badge
  palette so muscle memory carries over:
  - `!` yellow — `needs-input` (agent blocked on approval)
  - `x` red — `error`
  - `●` green — `done` (unread)
  - `~` blue — `working`
  - blank — `ready` / `idle`
- **AGENT** — `c` claude / `o` opencode, colour-coded.
- **PROJECT** — canonical key from `projects.yaml`.
- **TITLE** — session title / last user prompt (Claude uses the most recent
  entry in `~/.claude/history.jsonl` for the sessionId; OpenCode uses
  `session.title` from the DB).
- **LOCATION** — `<tmux_session>:<window>.<pane>` for live sessions,
  `detached` otherwise.
- **AGE** — time since the last update.

Rows are sorted by state priority descending (`needs-input > error > done >
working > ready > idle`), then by recency descending within a state.

## Data sources

- **Claude Code — live:** `~/.claude/sessions/<PID>.json`. Liveness is
  verified with `kill -0 <PID>`. Provides sessionId, cwd, name (title),
  status (busy/idle), and last-updated timestamp.
- **Claude Code — detached:** `~/.claude/history.jsonl` grouped by
  `sessionId`, keeping the most-recent entry per session. Only sessions the
  user has actually typed into show up — the JSONL transcript directory
  is intentionally NOT scanned to avoid noise from agent-only sessions.
- **OpenCode:** `~/.local/share/opencode/opencode.db`, `session` table
  filtered by `time_updated >= now - 7d` and `time_archived IS NULL`. The
  DB is read in WAL / read-only mode so concurrent writers are safe.
- **Status overlay:** `@tpm-agent-status-<source>-<id>` tmux options
  published by the status adapters (see
  [../integrations/README.md](../integrations/README.md)). This is the
  authoritative signal for semantic state; when unset, the row falls back
  to the underlying source's idle/busy hint.
- **Tmux location:** correlated per-pane via `tmux list-panes -a` plus
  `pgrep -P <pane_pid>` to catch Claude Code which runs as a child of the
  pane's shell.

## Filtering

Rows are filtered to projects registered in `projects.yaml`. Anything whose
cwd doesn't match a project's `path` (or a descendant of one) is dropped.
Longest-prefix wins when a cwd matches multiple project paths.

Cutoff for detached rows: **7 days** (`TPM_DASHBOARD_CUTOFF_DAYS`, override
via environment). Older sessions are silently skipped.

## Actions

| Key      | Behaviour                                                    |
|----------|--------------------------------------------------------------|
| `enter`  | On a **live** row: `switch-client` to that pane. On a **detached** row: dispatch to `integrations/<agent>-tpm-resume.sh`. |
| `ctrl-r` | Refresh — re-query every source and rebuild the list.        |
| `ctrl-a` | Acknowledge `done` state on **this row's agent session** (row-scoped — clears only this session's per-source entry, unlike focus-based ack which folds every done in the tmux session at once). No-op with a message if the row isn't currently in `done`. |
| `esc`    | Close the popup.                                             |

### Detached-row resume behaviour

Delegated to per-agent hook scripts under `integrations/`:

- **Claude Code** (`claudecode-tpm-resume.sh`) — opens a new window named
  `claude:<8-char-uuid>` in the project's tmux session running
  `claude --resume <full-uuid>`. If the managed tmux session doesn't exist
  yet it's launched first (via `scripts/launch.sh`). Repeat clicks are
  idempotent — the same short-uuid → same window name → reuse.
- **OpenCode** (`opencode-tpm-resume.sh`) — OpenCode's TUI hosts multiple
  sessions per process and doesn't expose an "activate session X" API. So
  Enter on a detached OpenCode row **navigates to the project's OpenCode
  presence** rather than restoring the specific session id:
  1. Live opencode pane in the project's tmux session → focus it.
  2. No live opencode but project's `tool` is opencode → repair the
     session and focus the tool window.
  3. No managed tmux session → launch via `scripts/launch.sh`.
  4. Managed session exists but project's tool isn't opencode → error out.
  The row's session id is displayed in the preview so it can be resumed
  manually (`/sessions` in the TUI).

## Configuration

Set in `.tmux.conf`:

```tmux
set -g @tpm-dashboard-key       'M-o'   # default binding
set -g @tpm-dashboard-no-prefix 'on'    # 'on' = no-prefix, 'off' = prefix+key
```

Environment overrides (for scripts / tests):

```sh
TPM_DASHBOARD_CUTOFF_DAYS=14   # widen the detached window
TPM_CLAUDE_DIR=~/.claude       # override the Claude Code data directory
TPM_OPENCODE_DB=~/.local/share/opencode/opencode.db
```

## Known limitations (v1)

See [dashboard-future-work.md](./dashboard-future-work.md) for the full
findings and v2 candidates. In brief:

- **OpenCode detached rows cannot answer pending prompts.** The
  interactive control that would answer a stored `needs-input` state
  died with the original process. Detached OpenCode rows show a `↪`
  glyph in the location column to indicate "attach yourself manually if
  you want to see the specific session" — but note that even manually
  attaching won't re-render outstanding interactive controls.
- **OpenCode session disambiguation** — one OpenCode process hosts many
  sessions but tmux only knows about the process. When multiple sessions
  share the same running process, all show the same tmux location. State
  is still correct (from `@tpm-agent-status-opencode-<id>`); location is
  best-effort.
- **In-place OpenCode resume** — not attempted; we route to project
  presence instead. Same reasoning as above.
- **`ctrl-x` kill** — deliberately omitted. Killing an OpenCode process
  affects every session that process owns, which contradicts the
  row-level abstraction. Use `tmux kill-pane` manually if needed.
- **No auto-refresh** — the dashboard is a snapshot. `ctrl-r` to re-run.

## Troubleshooting

**"no agent sessions in the last 7d"** — either no agent has been active
recently, or every recent cwd falls outside any project in
`projects.yaml`. Verify with:

```sh
sqlite3 ~/.local/share/opencode/opencode.db \
  "SELECT id, directory, datetime(time_updated/1000,'unixepoch') FROM session ORDER BY time_updated DESC LIMIT 5;"
```

**A live agent doesn't appear** — check the adapter is installed and
publishing:

```sh
tmux show-options -t "=<session>:" | grep '@tpm-agent-status'
```

If empty, run `integrations/install.sh --status` and re-install.

**Wrong location for OpenCode row** — this is the 1-process-N-sessions
issue documented above. Refresh (`ctrl-r`) picks up any recent adapter
writes that would disambiguate further.
