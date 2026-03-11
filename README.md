# todo

Minimal task manager optimized for [Claude Code](https://claude.ai/code).

Each todo has a `notes.md` file that gets injected into Claude's context when you start a session, so Claude always knows what you're working on. All commands are accessible by Claude via the CLI — no interactive UI required.

## Install

```bash
git clone <repo-url> ~/Dev/claude-todo
cd ~/Dev/claude-todo
./install.sh
```

This installs dependencies (`jq`, `fzf`, `gum`) via Homebrew, symlinks `todo` to `~/.local/bin`, and copies the default settings. Make sure `~/.local/bin` is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Dependencies

| Tool | Purpose |
|------|---------|
| [jq](https://github.com/stedolan/jq) | JSON processing |
| [fzf](https://github.com/junegunn/fzf) | Fuzzy picker |
| [gum](https://github.com/charmbracelet/gum) | Interactive prompts |
| [Claude Code](https://claude.ai/code) | AI coding sessions |

## Quick Start

```bash
todo new "Fix the login bug"   # Create a todo
todo                            # Open the picker — select to start working
todo done                       # Mark it as done when finished
```

## Commands

All commands accept an optional `[id]` (or ID prefix) to skip the interactive picker. This makes them usable by AI agents non-interactively.

### Core

| Command | Description |
|---------|-------------|
| `todo` | Open the fzf picker (create or select a todo) |
| `todo new "title"` | Create a new todo |
| `todo done [id]` | Mark a todo as done (optionally cleans up worktree/branch) |
| `todo delete [id]` | Delete a todo and all related data (notes, worktree, branch) |
| `todo list` | List all active todos |
| `todo archive` | Show completed todos |

### Notes

| Command | Description |
|---------|-------------|
| `todo edit [id]` | Open notes in your editor |
| `todo note <id> "text"` | Append text to a todo's notes (non-interactive) |
| `todo show [id]` | Print the absolute path to notes.md |

### Linking

| Command | Description |
|---------|-------------|
| `todo link [id] [url/path]` | Link a Linear ticket, GitHub URL, or notes file |
| `todo open` | Open Linear ticket or GitHub branch/PR in browser |
| `todo get <id>` | Print todo as JSON |

`todo link` auto-detects the type from the input:

```bash
todo link abc123 https://linear.app/team/CORE-456       # Linear ticket
todo link abc123 https://github.com/org/repo/pull/789   # GitHub PR
todo link abc123 https://github.com/org/repo/tree/feat  # Git branch
todo link abc123 ~/vault/my-notes.md                    # External notes file
```

### Subtasks

| Command | Description |
|---------|-------------|
| `todo split [id] ["title"]` | Create a subtask under a parent todo |

Subtasks inherit their parent's branch, worktree, and Linear ticket. Metadata that matches the parent is deduplicated in the picker view.

## Picker

The fzf picker is the main interface. It shows all todos with their status, branch, worktree directory, and age.

**Keybindings:**
- `enter` — Select a todo (opens action menu)
- `ctrl-d` — Toggle showing/hiding completed todos
- `esc` — Quit

When you select a todo, a menu offers:

- **Resume/Start Claude session** — launches Claude with your notes injected as context
- **Start Claude (new worktree)** — creates a git worktree with a dedicated branch
- **Start Claude (current dir)** — starts a session in the current directory
- **Promote to main repo** — moves a worktree branch back to the main repo checkout
- **Move to worktree** — moves a main-repo branch into its own worktree
- **Edit notes** — open notes in your editor
- **Open Linear / Open GitHub** — open linked URLs in browser
- **Split into subtask** — break work into smaller pieces
- **Mark as done** — complete the todo

## Worktrees

Todos can optionally use [git worktrees](https://git-scm.com/docs/git-worktree) for branch isolation. When you choose "Start Claude (new worktree)", a worktree is created at `.claude/worktrees/<slug>` with a branch named `todo/<slug>`.

- **Promote**: moves a worktree branch to the main repo checkout (removes the worktree, checks out the branch in the main repo, migrates the Claude session)
- **Demote**: moves a main-repo branch into a new worktree (with session migration)
- **Done**: optionally cleans up the worktree and branch when marking complete
- **Delete**: removes the worktree, branch, notes, and todo record

## Claude Integration

When you start or resume a Claude session from a todo, the tool:

1. Injects the todo's `notes.md` into Claude's system prompt via `--append-system-prompt`
2. For subtasks, also includes the parent's notes for context
3. Tracks the session ID and working directory so you can resume later

Claude can also use `todo` commands directly to manage work:

```bash
todo new "Refactor auth middleware"
todo note abc123 "Decided to use JWT instead of sessions"
todo link abc123 https://github.com/org/repo/pull/456
todo done abc123
todo delete abc123 --force
```

## Configuration

Settings live at `~/.config/claude-todo/settings.json`:

```json
{
  "data_dir": "~/.claude-todos",
  "repo": "",
  "editor": ""
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `data_dir` | Where todos and notes are stored | `~/.claude-todos` |
| `repo` | Git repo root (auto-detected if empty) | auto |
| `editor` | Editor for notes | `$VISUAL` / `$EDITOR` / `open` |

Environment variables override settings: `TODO_DATA_DIR`, `TODO_REPO`, `TODO_EDITOR`.

## Data

```
~/.claude-todos/
  todos.json              # All todo records
  notes/
    <id>/notes.md         # Notes for each todo
```

Each todo record contains:

```json
{
  "id": "1773202250-266f62",
  "title": "Fix the login bug",
  "created_at": "2026-03-11T15:30:00Z",
  "status": "active",
  "branch": "todo/fix-the-login-bug",
  "worktree_path": "/path/to/repo/.claude/worktrees/fix-the-login-bug",
  "notes_path": "~/.claude-todos/notes/1773202250-266f62/notes.md",
  "linear_ticket": "CORE-456",
  "github_pr": "https://github.com/org/repo/pull/789",
  "session_id": "a1b2c3d4-...",
  "session_cwd": "/path/to/repo",
  "parent_id": "",
  "last_opened_at": "2026-03-11T16:00:00Z"
}
```
