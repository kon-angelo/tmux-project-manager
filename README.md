# tmux-project-manager

Manage project sessions in tmux. One session per project, with dedicated windows for your AI tool, editor, and shells.

## Features

- **Project picker** (`M-p`): fzf popup with preview pane showing session state, git info, and action keybinds
- **Session lifecycle**: launch, repair, and kill project sessions
- **Current project detection**: highlights your active project via longest-path match
- **Session cycling** (`prefix [` / `prefix ]`): navigate between project sessions (skips ad-hoc sessions)
- **Filter toggle**: switch between all projects and running-only view
- **Status bar**: exposes `#{@project-name}` for your tmux status line

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

# Keybinds (defaults shown)
#   - Picker:  M-p (no-prefix global)
#   - Cycle:   prefix [ / prefix ]  (prefix-based to avoid escape-sequence
#              collisions; bare M-[ / M-] are CSI/OSC prefixes and
#              terminals intercept them before tmux sees them)
set -g @tpm-picker-key "M-p"
set -g @tpm-picker-no-prefix "on"
set -g @tpm-prev-key "["
set -g @tpm-next-key "]"
set -g @tpm-cycle-no-prefix "off"
```

## Keybinds

### Default

| Key | Action |
|-----|--------|
| `M-p` | Open project picker (no prefix) |
| `prefix [` | Switch to previous project session |
| `prefix ]` | Switch to next project session |

To bind cycling to a no-prefix combo (e.g. `M-,` / `M-.`), set:

```tmux
set -g @tpm-cycle-no-prefix "on"
set -g @tpm-prev-key "M-,"
set -g @tpm-next-key "M-."
```

### Inside the Picker

| Key | Action |
|-----|--------|
| `enter` | Switch to project (launch if not running) |
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
3. **Cycling**: `prefix [` / `prefix ]` only cycles through sessions tagged as project-managed, ignoring ad-hoc sessions.
4. **Detection**: The picker highlights your current project by matching `$PWD` against project paths (longest prefix wins).

## Status Bar

Use `#{@project-name}` in your status line to show the active project:

```tmux
set -g status-right "#{@project-name} | %H:%M"
```

## Related Tools

- [tmux-harpoon](https://github.com/kon-angelo/tmux-harpoon) — ad-hoc window bookmarking (orthogonal)
- [tmux-claude-session-manager](https://github.com/kon-angelo/tmux-claude-session-manager) — per-pane tool toggling (coexists, may be superseded)

## License

[MIT](LICENSE) © 2026 Konstantinos Angelopoulos
