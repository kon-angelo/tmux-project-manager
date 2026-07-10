# Agent Status Integrations

Two thin adapters that publish agent activity into tmux options so the tpm
project picker (`M-p`) can show which projects are waiting for you, working,
done, or errored.

Both are standalone: they don't depend on peon-ping or any other tool.

## Quick install

```sh
./install.sh
```

Detects `opencode` and `claude` on your `$PATH` and wires up whatever is
present. Safe to re-run — idempotent. Backups are created for every write.

```sh
./install.sh --dry-run       # show what would change, don't touch anything
./install.sh --only opencode   # limit to one integration
./install.sh --uninstall     # remove symlinks and hook entries
```

## Status vocabulary

See [../docs/agent-status.md](../docs/agent-status.md) for the option
namespace and priority rules. Short version:

| State         | Meaning                              | Badge in picker |
|---------------|--------------------------------------|-----------------|
| `needs-input` | Agent blocked on approval / prompt   | `!` yellow      |
| `error`       | Agent hit an error                   | `x` red         |
| `done`        | Agent finished, output unread        | `●` green       |
| `working`     | Agent is busy                        | `~` dim         |
| `ready`       | Agent idle at the initial prompt     | (none)          |

`done` is cleared automatically when you focus the session. `needs-input`
and `error` remain until the agent (or you) resolve them.

## What the installer does

### OpenCode

Creates a symlink at `~/.config/opencode/plugins/tpm-status.ts` pointing at
`opencode-tpm-status.ts` in this repo. Refuses to overwrite a non-symlink
so hand-edited plugins are safe.

Equivalent by hand:

```sh
mkdir -p ~/.config/opencode/plugins
ln -sf "$PWD/opencode-tpm-status.ts" ~/.config/opencode/plugins/tpm-status.ts
```

### Claude Code

Appends hook entries into `~/.claude/settings.json` under `hooks.<EventName>`
for these events:

- `SessionStart`
- `UserPromptSubmit`
- `Stop`
- `Notification`
- `PermissionRequest`
- `PostToolUseFailure`
- `SessionEnd`

Entries coexist with any pre-existing hooks (e.g. peon-ping) — the installer
appends, never replaces. Uses `jq` for structural edits and backs up the
file before every write.

Requires `jq` on the installer host. The hook script itself falls back to
grep+sed if `jq` isn't available at runtime, but the installer refuses to
touch settings.json without `jq`.

Manual equivalent (partial — the installer's idempotency and backup logic
would need re-implementing):

```json
{
  "hooks": {
    "Notification": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/absolute/path/to/claudecode-tpm-status.sh", "timeout": 5, "async": true}]}
    ]
  }
}
```

## Coexistence

Both integrations can run at the same time in the same tmux session — the
tpm scripts store per-source options (`@tpm-agent-status-opencode-<id>`,
`@tpm-agent-status-claudecode-<id>`) and pick the highest-priority state
across all of them.

## Post-install

Restart running `opencode` / `claude` sessions to pick up the new hook.
Existing sessions won't retroactively publish status.

## Debugging

Inspect a project session's raw status entries:

```sh
tmux show-options -t "=<session-name>:" | grep '@tpm-agent-status'
```

Force a recompute:

```sh
~/.tmux/plugins/tmux-project-manager/scripts/recompute-status.sh <session-name>
```

Clear a stuck status:

```sh
tmux set-option -t "=<session-name>:" -u @tpm-agent-status-<source>-<id>
~/.tmux/plugins/tmux-project-manager/scripts/recompute-status.sh <session-name>
```
