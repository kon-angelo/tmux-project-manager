# Agent Status Spec

External clients (AI coding agents, task runners, whatever) publish activity
into tmux session options so the tpm picker can render a badge per project.

## Option namespace

Two-tier scheme, per session:

| Option                                      | Written by  | Purpose                       |
|---------------------------------------------|-------------|-------------------------------|
| `@tpm-agent-status-<source>-<id>` = `<state>` | Client       | Per-source, per-instance state |
| `@tpm-agent-status` = `<state>`             | tpm scripts | Aggregated, read by the picker |

`<source>` is a short identifier for the integration (`opencode`, `claudecode`, …).
`<id>` is any string that uniquely identifies one instance of that source
within the session (typically the client's own session ID).

The picker never reads per-source options. The aggregator function in
`utils.sh` (`recompute_agent_status`) walks all `@tpm-agent-status-*` entries,
picks the highest-priority state, and writes it to `@tpm-agent-status`.

## States

Ordered high → low priority:

| Priority | State         | When to emit                                       |
|----------|---------------|----------------------------------------------------|
| 4        | `needs-input` | Blocked on a permission prompt or user input       |
| 3        | `error`       | Errored and stopped; requires attention            |
| 2        | `done`        | Finished successfully; user hasn't seen it yet     |
| 1        | `working`     | Currently processing                               |
| 0        | `ready`       | Session created, no work started                   |

Unset / empty means "no agent has reported into this session"; the picker
shows no badge.

## Writer protocol

```
# Write / update
tmux set-option -t "=<session>:" "@tpm-agent-status-<source>-<id>" "<state>"
~/.tmux/plugins/tmux-project-manager/scripts/recompute-status.sh <session>

# Clear (on client shutdown)
tmux set-option -t "=<session>:" -u "@tpm-agent-status-<source>-<id>"
~/.tmux/plugins/tmux-project-manager/scripts/recompute-status.sh <session>
```

Writers **should** call `recompute-status.sh` after every write. Writers
**must** clear their own entries on shutdown to avoid stale badges.

## Reader protocol

```
tmux show-option -t "=<session>:" -qv @tpm-agent-status
```

Returns the current aggregated state (or empty if none).

## Acknowledgement rules

`done` states are cleared automatically when the user focuses the session
(via the `client-session-changed` hook — see `update-status.sh`). This
gives "unread badge" semantics without dedicated dismiss actions.

`needs-input` and `error` are **not** cleared on focus — they mark
conditions that need explicit resolution by the agent (or a user action
inside the session), not just visual attention. Writers own the transition
out of these states.

`working` and `ready` are transient states owned by the writer; they will
be overwritten by the next state transition.

## Multi-agent sessions

Multiple agents may run in the same tmux session (e.g. one opencode + one
claudecode, or two claudecode instances in different windows). Each writes
its own `@tpm-agent-status-<source>-<id>` option; the aggregator picks the
highest priority. The picker therefore shows the "most urgent" state
across all agents.

## Design constraints

- **No polling.** All state transitions are event-driven; the picker reads
  the aggregate on open. The `update-status.sh` hook fires only when the
  user's session focus actually changes.
- **No external dependencies.** Reader and aggregator are pure bash + tmux.
  Writers may use whatever their runtime allows (TypeScript, bash, Go).
- **Sessions must exist.** All writes target `=<session>:` and no-op if
  the session is gone. Writers should check `tmux has-session` before
  writing on best-effort.
- **Only tpm-managed sessions receive writes.** Writers must check
  `@tpm-managed` before publishing so ad-hoc user sessions don't accumulate
  option state.
- **Sort order is untouched.** Status badges are visual decoration only;
  the picker's sort remains `current > running > stopped` with alpha/lru
  as secondary. Rationale: preserves muscle memory for alt-1..9 quick-picks.
