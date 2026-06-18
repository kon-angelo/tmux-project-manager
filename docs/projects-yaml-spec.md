# projects.yaml — Schema Reference

The projects registry is a standalone YAML file that serves as a canonical, tool-agnostic mapping of project names to filesystem paths and metadata. It is consumed by multiple tools:

- **tmux-project-manager** — session creation, picker, repair
- **task-agent** — route task workers to the correct directory/session
- **CLAUDE.md** — persona auto-loading per repo
- **Future tools** — anything that needs "which projects exist and where"

## Default Location

```
~/.config/projects/projects.yaml
```

Consumers should allow overriding this path via their own configuration (e.g., tmux option `@tpm-projects-file`, environment variable, CLI flag).

## Schema

```yaml
# Top-level: map of project-key → project definition
<project-key>:
  path: <string>              # REQUIRED. Absolute filesystem path.
  aliases: [<string>, ...]    # Optional. Short names. First alias = tmux session name.
  description: <string>       # Optional. One-line description shown in picker/preview.
  tool: <string>              # Optional. AI tool command (default: "opencode").
  editor: <string>            # Optional. Editor command (default: "nvim").
  nvim: <boolean>             # Optional. Whether to create editor window (default: true).
  personas: [<string>, ...]   # Optional. Persona files for AI agent guidance.
```

## Field Details

### `path` (required)

Absolute path to the project root directory. Used as:
- `cwd` for all windows in the project session
- Match target for current-project detection (longest prefix match against `$PWD`)

### `aliases` (optional)

List of short names for the project. The **first alias** is used as the tmux session name. Additional aliases can be used for fuzzy matching in pickers or task routing.

If omitted, the `<project-key>` itself is used as the session name.

### `description` (optional)

Human-readable description. Shown in the picker's preview pane and help text.

### `tool` (optional)

Command to run in window 0 (`claude` window). Examples: `opencode`, `claude`.

Default: value of tmux option `@tpm-default-tool` (which itself defaults to `opencode`).

### `editor` (optional)

Command to run in window 1 (`editor` window). Examples: `nvim`, `hx`, `vim`.

Default: value of tmux option `@tpm-default-editor` (which itself defaults to `nvim`).

### `nvim` (optional)

Boolean. Whether to create the editor window (window 1) at all.

- `true` (default): editor window is created on launch and expected by repair.
- `false`: no editor window. Window 1 slot is available for user shells.

Note: the field is named `nvim` for backward compatibility but controls any configured editor.

### `personas` (optional)

List of persona file basenames (without `.md`) from the Obsidian vault's `personas/` directory. Used by AI agents (via CLAUDE.md) for code reviews and implementation guidance. Not used by tmux-project-manager directly.

Order signals priority — first persona is primary.

## Special Entries

### `_general`

A fallback entry for tasks/contexts not tied to any specific project:

```yaml
_general:
  path: /Users/username/workspace
  aliases: [general, none]
  description: General tasks not tied to a specific repository
```

This entry is used by task-agent for tasks without a `repo:` UDA. tmux-project-manager ignores entries starting with `_`.

## Example

```yaml
_general:
  path: /Users/d071996/SAPDevelop
  aliases: [general, none]
  description: General tasks not tied to a specific repository

dotfiles:
  path: /Users/d071996/SAPDevelop/dev/dotfiles
  aliases: [df, dots]
  description: Personal dotfiles — nvim, zsh, tmux, ghostty configs

gardener:
  path: /Users/d071996/SAPDevelop/go/src/github.com/gardener/gardener
  aliases: [gg]
  description: Kubernetes gardener core repository
  personas: [rfranzke]

gardener-extension-provider-azure:
  path: /Users/d071996/SAPDevelop/go/src/github.com/gardener/gardener-extension-provider-azure
  aliases: [ggaz, azext]
  description: Gardener extension provider for Azure
  tool: opencode
  personas: [rfranzke, andyzang]

tmux-harpoon:
  path: /Users/d071996/SAPDevelop/dev/tmux-harpoon
  aliases: [harpoon, th]
  description: tmux plugin — fast window bookmarking
  nvim: true
```

## Consumers

### tmux-project-manager

Reads: `path`, `aliases`, `description`, `tool`, `editor`, `nvim`
Config: `set -g @tpm-projects-file "~/.config/projects/projects.yaml"`

### task-agent

Reads: `path`, `aliases`
Config: `PROJECTS_FILE` variable in the script (currently hardcoded, will become configurable)

### CLAUDE.md / AI agents

Reads: `path`, `aliases`, `personas`
Config: referenced in CLAUDE.md global memory section

## Conventions

- Keys should be lowercase, hyphenated (e.g., `gardener-extension-provider-azure`)
- Aliases should be short (2-6 chars) for quick typing and tmux status bar display
- Paths must be absolute
- Entries starting with `_` are metadata/special and ignored by session-creating tools
