# Dashboard — Future Work & Findings

Notes from the v1 investigation. This file exists so that when we (or a
future contributor) come back to extend the dashboard, we don't
re-discover what we already learned about how OpenCode and Claude Code
actually behave — and where the ceilings are.

Scope: everything explicitly deferred, plus concrete architectural
observations that inform what a v2 could and could not achieve.

---

## Observed OpenCode session model

Verified empirically during v1 development (see the SSE experiment at the
end of this document for the exact multi-attach test).

### Storage vs. runtime

- **Persistence layer**: SQLite at `~/.local/share/opencode/opencode.db`
  in WAL mode. Every message, part, todo, session record, and permission
  record is durably written.
- **Runtime event bus**: in-process, TypeScript event emitter. Sessions,
  message parts, permission requests, and session state changes all
  propagate through this bus to the plugin API (which is what our
  `opencode-tpm-status.ts` adapter subscribes to).
- **Cross-process communication**: **none by default**. Two independently
  launched `opencode` processes on the same machine share SQLite but not
  the event bus. Neither knows the other exists.

### Server mode (`opencode --port N` / `opencode serve` / `opencode attach`)

- `opencode --port <port>` starts a normal TUI **plus** an HTTP server
  exposing session/event endpoints on `127.0.0.1:<port>`. The TUI
  becomes a thin client of its own in-process server.
- `opencode serve` starts a headless HTTP server (no TUI).
- `opencode attach http://127.0.0.1:<port>` connects a new TUI as a
  second client of an existing server. Events broadcast to every attached
  client via **Server-Sent Events** (SSE).
- Default (`opencode` with no `--port`) does NOT expose HTTP. Empirically
  confirmed: `lsof -iTCP -p <pid>` is empty for stock TUIs.

### Multi-attach empirical results

Ran the experiment: 2 TUIs attached before a permission/choice prompt
fired, 1 more attached after.

| Attached when? | Sees transcript? | Sees the choice UI? |
|----------------|------------------|---------------------|
| Before prompt  | Yes              | Yes — can answer    |
| After prompt   | Yes (from SQLite)| **No** — control gone |

SSE has no built-in event replay — subscribers only receive events from
their subscription time onward. Interactive controls (permission prompts,
choice widgets) are broadcast as one-shot events at the moment the agent
fires them. If nobody is listening at that instant, the interaction
opportunity is gone. The transcript record of "the agent asked X"
survives in SQLite; the runtime object that could accept Y/N/whatever is
process-local and dies with the process (or is missed by late joiners).

**Corollary:** `attach` is a live-observability tool, not a resurrection
tool. Detached sessions with pending prompts cannot be resumed to answer
those prompts by any mechanism available today. Solving this requires
OpenCode to add explicit "re-emit outstanding pending events on new
subscriber connect" semantics — a change on their side.

### 1-process-N-sessions

Every OpenCode process can host many sessions in its SQLite DB but only
displays one at a time in its TUI. There's no plugin-API event for
"user switched focus to session X" that we could find. This is the
reason the dashboard trusts `@tpm-agent-status-opencode-<id>` (published
by the adapter on session-lifecycle events) as authoritative for
live/detached classification, and doesn't try to infer live-ness from
process CWD matching (which the PoC found caused false-positive
"candidate" rows).

---

## Claude Code session model

Verified during v1 development (`claude --resume` works; interactive
state does not re-materialize).

- **Storage**: `~/.claude/sessions/<PID>.json` for live sessions,
  `~/.claude/projects/<slugified-cwd>/<uuid>.jsonl` for full transcripts,
  `~/.claude/history.jsonl` for cross-session prompt log.
- **Model**: 1-process-1-session. Every `claude` process owns exactly one
  session. Resume via `claude --resume <uuid>` in a fresh process.
- **Resume behavior**: loads the transcript. Does NOT re-emit outstanding
  interactive controls (permission prompts, MCP approvals). Same
  fundamental limitation as OpenCode's late-joiner problem, just with
  different mechanics.

Claude's 1:1 model made the v1 resume hook simple:
`claude --resume <uuid>` in a new window named `claude:<8-char>` per
session; window-name-based dedupe for repeat clicks.

---

## v2 candidate: managed `--port` + attach action

The most obvious extension enabled by everything we learned.

### Change

- `scripts/launch.sh` for OpenCode: always add `--port 0 --hostname
  127.0.0.1`. `--port 0` = OS picks a free port.
- After launch, discover the assigned port (`lsof -iTCP -p $pid | awk
  ...`) and store it in a per-session tmux option:
  `@tpm-opencode-url = http://127.0.0.1:<port>`.
- Dashboard row schema gains a "url" column populated from that option
  for live rows.
- New action `ctrl-w` on a **live** dashboard row: `tmux new-window` in
  the row's tmux session running `opencode attach <url>`. Gives you a
  second live-following view of that session.

### Value

- Multi-viewer observability (watch an agent work in one pane, edit in
  another).
- Preparatory work if OpenCode ever adds pending-event re-emission.
- Optional: dashboard preview could stream via SSE for a "live cinema"
  preview (probably too expensive to run continuously; could be
  behind a toggle).

### Costs

- Port management surface: assignment, discovery, cleanup on restart,
  handling of process restarts.
- All existing OpenCode sessions need to be re-launched under the new
  regime to acquire a port.
- Doesn't help detached-session resurrection at all — the biggest UX
  pain point is unchanged.
- Requires verifying whether attach clients are truly bidirectional or
  observer-only (need to send messages from an attached client and see
  if the server-side TUI accepts them as equal-priority input).

### Verdict

Worth prototyping only if the "watch an agent from another pane" use
case becomes compelling. Not blocking any current v1 workflow. Order of
implementation: verify `attach` bidirectionality first (5 min test), then
plumb `--port` if positive.

---

## v2 candidate: focused-session event for OpenCode

Would fully solve the 1-process-N-sessions ambiguity.

### What it would require

An event in the OpenCode plugin API when the user switches sessions
inside the TUI. Something like:

```ts
plugin.on('session.focus_changed', ({ sessionId }) => { ... })
```

Doesn't appear to exist as of investigation time. If it did, our
existing OpenCode adapter (`integrations/opencode-tpm-status.ts`) could
publish a `@tpm-active-opencode-session` tmux option, and the dashboard
would trivially know which session any given OpenCode pane is currently
displaying.

### Fallback if it can't be added

Current v1 works by trusting the per-session status option. Rows
without an option are marked detached. Works well for adapters-installed
sessions; only misbehaves for OpenCode processes running outside a
managed tmux (rare in practice).

---

## v2 candidate: state re-hydration for pending prompts

The single biggest UX limitation. Currently unsolvable without upstream
changes.

### What it would require (OpenCode side)

Two possible mechanisms:

1. **Late-joiner replay.** On new SSE subscriber, the server replays all
   currently-outstanding events (permission requests, pending choice
   prompts, etc.). Would allow `attach` to be a true "join and interact"
   operation.
2. **Persistent pending state.** Serialize enough of the runtime
   interactive-control object into `session.permission` (already exists)
   or a similar table that a *newly launched* process resuming the
   session can reconstruct the interactive control. Would allow
   `opencode -s <id>` on a detached session to actually work.

### What it would require (Claude Code side)

Analogous problem, analogous fixes. Claude's simpler 1:1 model means
option 2 (persistent pending state) is likely easier — the resume path
would just check for outstanding pending prompts on load and re-render
them in the TUI.

### Verdict

Both are upstream changes. Not in our control. If either agent adds
support, the dashboard's detached-row semantics get much better
automatically.

---

## Small refinements deferred from v1

These are candidates for a v1.1 or v2 focused polish pass — small
enough individually that they aren't worth their own project:

- **fzf query filters via `--tiebreak=chunk` + typed prefixes**:
  `agent:claude`, `state:working`, `project:gg`. Trivial once the
  search-field metadata is included in the display column.
- **`ctrl-x` kill**: safe for Claude (1:1), UX-hazardous for OpenCode
  (kills every session the process hosts). Needs a confirmation
  prompt or restrict-to-Claude-only for v1.1.
- **`?` help pane** overlay listing all keybinds.
- **Autorefresh timer** (behind `@tpm-dashboard-autorefresh` off by
  default). fzf's `--reload` action could fire every N seconds.
- **tq cross-reference**: show `tq wip` tasks alongside their repo's
  sessions so the task board and the agent dashboard cross-reference.
- **Row-scoped kill of a Claude session**: `SIGTERM` to the
  session's PID from the dashboard. Non-destructive for OpenCode is
  hard; for Claude it's trivial and low-risk.

---

## What v1 explicitly does NOT do (and why)

Repeated here so future maintainers understand the intent:

- **Detached-row `enter` does not resume the exact OpenCode session id.**
  We route to the project's existing OpenCode presence instead
  (`opencode-tpm-resume.sh`). This is correct given the multi-attach
  findings above: routing to a live-elsewhere session buys nothing when
  the interactive state is gone.
- **Detached-row `enter` for Claude opens a new window with
  `claude --resume`.** Non-destructive to any live Claude in the tool
  window. Idempotent per session-id (dedup on window name). This works
  because Claude Code is 1:1 and its resume-command exists; the fact
  that pending prompts don't re-materialize is documented but not
  something we can fix from here.
- **No `--port` plumbing in `launch.sh` for OpenCode.** Adding server
  mode by default is a significant surface for zero UX benefit until
  server-mode-specific features (v2 candidates above) are actually
  built.
- **No auto-refresh.** Snapshot model matches the picker. `ctrl-r` is
  cheap enough (~200ms on this machine for 25 rows) that manual refresh
  is fine.
- **No `ctrl-x` kill in v1.** OpenCode's 1-process-N-sessions makes
  row-scoped kill impossible without killing sibling sessions. Adding
  it Claude-only would create asymmetric UX that's arguably worse than
  the current absence.

---

## Appendix: SSE multi-attach experiment (11 Jul 2026)

Reproducible steps that verified everything above.

### Setup

- Terminal A: `opencode --port 4567` — starts opencode with SSE server.
- Terminal B: `opencode attach http://127.0.0.1:4567` — attaches as
  observer #1.

### Test 1 — early joiners

- With B already attached, in A (or via message) trigger a multiple-
  choice prompt (e.g. the `question` plugin tool, or a permission
  request from a file-write tool call).
- **Observation:** Both A and B render the choice UI. Answering in
  either updates both.

### Test 2 — late joiner

- Terminal C: `opencode attach http://127.0.0.1:4567` — attaches AFTER
  the choice prompt has fired in A/B.
- **Observation:** C sees the transcript (the question text is in
  SQLite) but does NOT render the choice UI. Cannot answer from C.
  Answering from A/B still works.

### Conclusion

SSE broadcasts events at emission time only. Late joiners miss the
interactive-control event forever. This is by design for SSE and would
need explicit re-emission on the OpenCode side to change.
