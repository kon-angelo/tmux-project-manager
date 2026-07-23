# tmux-project-manager

Manage project sessions in tmux. One session per project, with dedicated windows for your AI tool, editor, and shells.

## Features

- **Project picker** (`M-p`): fzf popup with preview pane showing session state, git info, and action keybinds
- **Session lifecycle**: launch, repair, and kill project sessions
- **Current project detection**: highlights your active project via longest-path match
- **Session cycling** (`prefix {` / `prefix }`): navigate between project sessions (skips ad-hoc sessions)
- **Window carousel** (`M-g`): cycle within a project session: claude → editor → last shell
- **Agent dashboard** (`M-o`): fzf overview of every Claude + OpenCode session across projects, live and detached, with real-time status (see [docs/dashboard.md](docs/dashboard.md))
- **Filter toggle**: switch between all projects and running-only view
- **Status bar**: exposes `#{@project-name}` for your tmux status line
- **Agent status badges**: picker renders a coloured glyph per project when an AI agent inside the session needs attention (see [docs/agent-status.md](docs/agent-status.md) and [integrations/](integrations/))

## Requirements

- tmux >= 3.2 (popup support)
- [TPM](https://github.com/tmux-plugins/tpm) (tmux plugin manager)
- [fzf](https://github.com/junegunn/fzf)
- [yq](https://github.com/mikefarah/yq) (YAML parser)
- git (optional, for preview branch info)

## Installation

Add to your `.tmux.conf`:

```tmux
set -g @plugin 'kon-angelo/tmux-project-manager'
```

Then press `prefix + I` to install via TPM.

## Configuration

### Projects File

Create `~/.config/projects/projects.yaml`:

```yaml
dotfiles:
  path: /Users/me/dotfiles
  aliases: [df, dots]
  description: Personal dotfiles
  tool: opencode
  editor: nvim

my-app:
  path: /Users/me/projects/my-app
  aliases: [app]
  description: Main application
  nvim: false  # skip editor window
```

See [docs/projects-yaml-spec.md](docs/projects-yaml-spec.md) for the full schema.

### Tmux Options

```tmux
# Path to projects registry (default: ~/.config/projects/projects.yaml)
set -g @tpm-projects-file "~/.config/projects/projects.yaml"

# Default tool for window 0 (default: opencode)
set -g @tpm-default-tool "opencode"

# Default editor for window 1 (default: nvim)
set -g @tpm-default-editor "nvim"

# Keybinds — nothing is bound by default. Opt in per action by setting the
# key; leave empty (the default) to skip the bind entirely. Each key can be
# routed through the root table (no-prefix, "on") or the prefix table
# ("off") via the paired @tpm-*-no-prefix option.
#
# Example: everything under Alt (no-prefix) except cycle, which stays on
# the prefix table because prefix+{ / prefix+} sit next to tmux's other
# window ops.
set -g @tpm-picker-key    "M-p"    # project picker
set -g @tpm-picker-no-prefix "on"
set -g @tpm-dashboard-key "M-o"    # agent-session dashboard
set -g @tpm-dashboard-no-prefix "on"
set -g @tpm-carousel-key  "M-g"    # cycle claude → editor → shell in-session
set -g @tpm-carousel-no-prefix "on"
set -g @tpm-prev-key      "{"      # prev project session (needs @tpm-next-key too)
set -g @tpm-next-key      "}"
set -g @tpm-cycle-no-prefix "off"  # 'on' to route prev/next through the root table
```

Key-choice notes if you're picking your own:

- **Picker / dashboard / carousel**: no-prefix Alt combos work best. Plain
  letters (Alt+p, Alt+g, Alt+o, Alt+t, Alt+y, …) avoid escape-sequence
  collisions across Ghostty / iTerm / Alacritty / kitty / Linux terminals.
- **Cycle (prev/next)**: `prefix { / prefix }` shadows swap-pane -U/-D, but
  those have `prefix+<>` and no-prefix `M-HJKL` alternatives, so the
  collision is benign. Bare `M-[ / M-]` intercept CSI/OSC prefixes.
  `M-{ / M-}` require Shift and behave inconsistently on macOS/Ghostty.
  `prefix+[ / prefix+]` steal copy-mode and paste-buffer — best avoided.

## Keybinds

### Actions

The plugin ships **no default bindings** — set the corresponding
`@tpm-*-key` option (see [Tmux Options](#tmux-options)) to opt in.

| Action | Option | Script |
|--------|--------|--------|
| Project picker | `@tpm-picker-key` | `scripts/picker.sh` |
| Agent-session dashboard | `@tpm-dashboard-key` | `scripts/dashboard.sh` |
| Prev / next project session | `@tpm-prev-key` / `@tpm-next-key` | `scripts/cycle.sh` |
| In-session carousel | `@tpm-carousel-key` | `scripts/carousel.sh` |

You can also call any script directly, e.g. from another plugin:

```tmux
bind-key -n M-y run-shell -b "~/.tmux/plugins/tmux-project-manager/scripts/picker.sh"
```

### Inside the Picker

| Key | Action |
|-----|--------|
| `enter` | Switch to project (launch if not running) |
| `alt-1` … `alt-9` | Quick-pick the Nth visible row (same effect as Enter on it) |
| `ctrl-r` | Repair: recreate missing managed windows |
| `ctrl-x` | Kill project session |
| `ctrl-n` | Add a new shell window |
| `ctrl-e` | Ensure editor window exists |
| `ctrl-f` | Toggle filter: all / running only |

## Session Layout

Each project session has a fixed structure:

| Window | Name | Content |
|--------|------|---------|
| 0 | `claude` | AI tool (opencode, claude, etc.) |
| 1 | `editor` | Editor (nvim, helix, etc.) — optional |
| 2+ | `shell` | User shells, task workers |

## How It Works

1. **Launch**: Creates a tmux session named after the project's first alias, spawns tool + editor windows, tags the session as managed.
2. **Repair**: Checks that windows 0 and 1 exist with correct names. Recreates missing ones without touching user-created windows (2+).
3. **Cycling**: `prefix {` / `prefix }` only cycles through sessions tagged as project-managed, ignoring ad-hoc sessions.
4. **Carousel**: `M-g` cycles through `claude → editor → last shell` within the current project session. If no shell window exists, one is created at the project's path.
5. **Detection**: The picker highlights your current project by matching `$PWD` against project paths (longest prefix wins).
6. **Persistence**: Compatible with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect). The plugin registers a `@resurrect-hook-post-restore-all` hook that re-applies the project-managed tags to restored sessions whose names match a project alias. If you already have a hook set, ours is appended (not overwritten).

## Status Bar

Use `#{@project-name}` in your status line to show the active project:

```tmux
set -g status-right "#{@project-name} | %H:%M"
```

## Agent Status Badges

If you run coding agents (OpenCode, Claude Code, …) inside project sessions,
the picker can show a per-project badge indicating whether the agent needs
attention:

| Badge | State         | Meaning                              |
|-------|---------------|--------------------------------------|
| `!`   | `needs-input` | Agent blocked on approval / prompt   |
| `x`   | `error`       | Agent hit an error                   |
| `●`   | `done`        | Agent finished, output unread        |
| `~`   | `working`     | Agent is busy                        |
|       | `ready`       | Agent idle at the initial prompt     |

The picker sort order is unchanged — badges are decoration only, not a
priority queue. `done` clears when you focus the session.

Wire up your agents via the adapters in [`integrations/`](integrations/) —
they publish per-source state into tmux options and the picker aggregates
across sources. Run the installer from the TPM-installed copy to auto-detect
and set them up:

```sh
~/.tmux/plugins/tmux-project-manager/integrations/install.sh
```

See [docs/agent-status.md](docs/agent-status.md) for the option namespace
and priority rules.

## Related Tools

- [tmux-harpoon](https://github.com/kon-angelo/tmux-harpoon) — ad-hoc window bookmarking (orthogonal)
- [tmux-claude-session-manager](https://github.com/kon-angelo/tmux-claude-session-manager) — per-pane tool toggling (coexists, may be superseded)

## License

[MIT](LICENSE) © 2026 Konstantinos Angelopoulos
