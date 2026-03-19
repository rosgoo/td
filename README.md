```
  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄
    █    █   █ █    █ █   █
    █    █   █ █    █ █   █
    █    █▄▄▄█ █▄▄▄▀  █▄▄▄█
```

Minimal task and session manager for agentic coding.

## Features

- **Session persistence** — links Claude sessions and working directories to tasks so you can resume exactly where you left off and reduce context overload
- **Plan-aware sessions** — each todo has a `plan.md` that gets injected into Claude's system prompt, so context carries across sessions automatically
- **Subtasks** — break todos into smaller pieces that inherit their parent's branch, worktree, and links
- **`td do`** — create a todo and drop into a Claude session directly (run with no name to get a random NYC-inspired name)
- **`/td` slash command** — manage todos from inside any Claude Code session
- **Git worktree isolation** — optionally spin up a dedicated worktree and branch per todo, keeping work separated
- **`td try`** — test worktree changes on your main repo without switching directories, reinstalling dependencies, or rebuilding
- **Linear & GitHub linking** — attach tickets, PRs, and branches to todos; open them from the picker
- **Pre-compact hook** — automatically snapshots conversation context into `plan.md` before Claude compacts, so notes are never lost
- **Non-interactive CLI** — every action has an ID-addressable command, so Claude (or scripts) can manage todos without a UI
- **Self-updating** — `td update` pulls the latest release

## Quick Start

```bash
td do "Fix the login bug"       # Create a todo and start Claude immediately
td do                            # Same thing — suggests a random NYC name
td                               # Open the picker — select to resume the session
td done                          # Mark it as done when finished
```

Inside a Claude session, use the `/td` slash command to manage todos without leaving the conversation.

---

## Installation

Requires **Python 3.10+**. Check your version:

```bash
python3 --version
```

Most macOS users already have Python 3 via Xcode command line tools or Homebrew. If not:

```bash
brew install python    # macOS
# or visit https://python.org/downloads
```

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash
```

This downloads the latest release, installs the Python package (via pipx, pip, or a managed venv), and sets up the Claude Code hook and `/td` slash command. fzf is bundled — no separate install needed. Make sure `~/.local/bin` is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

To update:

```bash
td update
```

### Other install methods

**pip / pipx:**

```bash
pipx install td-cli    # isolated install (recommended)
pip install td-cli     # or pip
```

**From source (for development):**

```bash
git clone https://github.com/rosgoo/td.git
cd td
./dev-install.sh    # creates .venv, installs editable, sets up td + td-prod
```

This gives you `td` pointing to the Python dev version (editable — changes to `src/` take effect immediately) and `td-prod` pointing to the bash production version.

### Hook configuration

The installer automatically injects the PreCompact hook into `~/.claude/settings.json`. To skip this, pass `--no-hooks`:

```bash
curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash -s -- --no-hooks
```

To configure the hook manually instead, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "td-pre-compact",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### Editor setup

**Obsidian:**

Set `editor` to `"obsidian"` in your settings to open notes directly in Obsidian using the URI scheme. Your `data_dir` must be inside (or be) an Obsidian vault:

```json
{
  "data_dir": "~/td",
  "editor": "obsidian"
}
```

`td edit` will open the note via `obsidian://open?vault=td&file=...`, navigating directly to the file. You can also create folders directly in Obsidian and run `td sync` to import them as todos.

**Cursor:**

Set `editor` to `"cursor"` to open notes in Cursor:

```json
{
  "editor": "cursor"
}
```

This uses the `cursor` CLI command, which Cursor installs via **Cursor > Install 'cursor' command** in the command palette.

### Dependencies

| Tool | Purpose |
|------|---------|
| [Python 3.10+](https://python.org) | Runtime |
| [Claude Code](https://claude.ai/code) | AI coding sessions |

Python packages (installed automatically): [typer](https://typer.tiangolo.com), [rich](https://rich.readthedocs.io), [iterfzf](https://github.com/dahlia/iterfzf) (bundles fzf).

---

## Commands

All commands accept an optional `[id]` (or ID prefix) to skip the interactive picker. This makes them usable by AI agents non-interactively.

### Core

| Command | Description |
|---------|-------------|
| `td` | Open the fzf picker (create or select a todo) |
| `td new "title"` | Create a new todo |
| `td do ["title"]` | Create a todo and immediately open a Claude session (random name if omitted) |
| `td open [id]` | Open the action menu for a todo (resume session, link, done, etc.) |
| `td done [id]` | Mark a todo as done (optionally cleans up worktree/branch) |
| `td rename [id] "title"` | Rename a todo |
| `td delete [id]` | Delete a todo and all related data (notes, worktree, branch) |
| `td list` | List all active todos |
| `td archive` | Show completed todos |

### Plans & Notes

| Command | Description |
|---------|-------------|
| `td edit [id]` | Open notes in your editor |
| `td plan <id>` | Print the plan contents |
| `td plan <id> "text"` | Append text to a todo's plan (non-interactive) |
| `td plan <id> --replace <file>` | Replace plan.md with an existing file |
| `td plan <id> -o` | Open plan.md in your editor |
| `td show [id]` | Print the absolute path to plan.md |

### Linking

| Command | Description |
|---------|-------------|
| `td link [id] [url/path]` | Link a Linear ticket, GitHub URL, or notes file |
| `td get <id>` | Print todo as JSON |

`td link` auto-detects the type from the input:

```bash
td link abc123 https://linear.app/team/CORE-456       # Linear ticket
td link abc123 https://github.com/org/repo/pull/789   # GitHub PR
td link abc123 https://github.com/org/repo/tree/feat  # Git branch
td link abc123 ~/vault/my-notes.md                    # External notes file
```

### Subtasks

| Command | Description |
|---------|-------------|
| `td split [id] ["title"]` | Add a subtask under a parent todo |

Subtasks inherit their parent's branch, worktree, and Linear ticket. Metadata that matches the parent is deduplicated in the picker view.

### Setup

| Command | Description |
|---------|-------------|
| `td init` | Configure settings interactively |
| `td settings` | Print the current settings file |

### Sync

| Command | Description |
|---------|-------------|
| `td sync` | Two-way sync: create todos for orphaned dirs, remove todos for missing dirs |
| `td sync -n` | Dry run — show what would happen without making changes |

If you create a folder in `~/td/todo/` manually (e.g. from Obsidian), `td sync` picks it up and creates a todo for it. If you delete a folder, `td sync` removes the orphaned todo. Nested subdirectories become subtasks automatically.

### Other

| Command | Description |
|---------|-------------|
| `td browse` | Open notes directory in your editor |
| `td update` | Update to latest version |
| `td version` | Print version |
| `td help` | Show help |

---

## Worktrees

Todos can optionally use [git worktrees](https://git-scm.com/docs/git-worktree) for branch isolation. When you choose "Start Claude (new worktree)" from the picker, a worktree is created at `.claude/worktrees/<slug>` with a branch named `todo/<slug>`.

### `td try`

Use `td try` to test worktree changes on your main repo without leaving the worktree. It diffs all changes from the worktree branch against main and applies them as a single commit on a `try-<slug>` branch in the main repo.

This avoids the pain of switching back to main just to test — no reinstalling dependencies, no rebuilding, no restarting dev servers. Your worktree stays untouched while you can run the full test suite or start the app from the main repo on the try branch.

```bash
td try           # pick a todo from the picker
td try abc123    # or pass an ID directly
```

### Lifecycle

- **Done** — `td done` optionally cleans up the worktree and branch
- **Delete** — `td delete` removes the worktree, branch, notes, and todo record

---

## Claude Integration

When you start or resume a Claude session from a todo, the tool:

1. Injects the todo's `plan.md` into Claude's system prompt via `--append-system-prompt`
2. For subtasks, also includes the parent's notes for context
3. Tracks the session ID and working directory so you can resume later

Claude can also use `td` commands directly to manage work:

```bash
td new "Refactor auth middleware"
td plan abc123 "Decided to use JWT instead of sessions"
td link abc123 https://github.com/org/repo/pull/456
td done abc123
td delete abc123 --force
```

### PreCompact hook

Before Claude Code compacts your conversation context (auto or manual), the `pre-compact` hook snapshots the conversation into your todo's `plan.md` under a `## Session Notes` section. Each compact appends a timestamped block with user/assistant messages, so context is never fully lost.

The hook only activates for sessions linked to a todo (matched by `session_id`). Sessions without a todo are unaffected.

---

## Configuration

Run `td init` to configure settings interactively. Run `td settings` to view the current settings file.

```bash
td init
```

This walks you through each setting:

```
  data_dir — Where todos and notes are stored
  Current: ~/td

  editor — Editor for opening plan.md files
  Examples: "code", "nvim", "open -a Obsidian"
  Current: (auto-detect from $EDITOR)

  ...
```

For example, to use **Obsidian** as your notes editor, set `editor` to `"obsidian"`. This opens notes directly in Obsidian via the URI scheme — your `data_dir` should be inside (or be) an Obsidian vault. See [Editor setup](#editor-setup) for more options.

Settings are saved to `~/.config/claude-todo/settings.json`:

```json
{
  "data_dir": "~/td",
  "repo": "",
  "editor": "obsidian",
  "linear_org": "",
  "worktree_dir": ".claude/worktrees",
  "branch_prefix": "todo"
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `data_dir` | Where todos and notes are stored | `~/td` |
| `repo` | Git repo root (auto-detected if empty) | auto |
| `editor` | Editor for notes | `$VISUAL` / `$EDITOR` / `open` |
| `linear_org` | Linear organization slug (for ticket URLs) | _(disabled)_ |
| `worktree_dir` | Worktree directory relative to repo root | `.claude/worktrees` |
| `branch_prefix` | Prefix for auto-created branches | `todo` |

Environment variables override settings: `TODO_DATA_DIR`, `TODO_REPO`, `TODO_EDITOR`, `TODO_LINEAR_ORG`, `TODO_WORKTREE_DIR`, `TODO_BRANCH_PREFIX`.

---

## Data

```
~/td/
  todos.json              # All todo records
  todo/
    <title>/plan.md       # Notes for each todo (+ session notes appended by hooks)
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
  "notes_path": "~/td/todo/Fix the login bug/plan.md",
  "linear_ticket": "CORE-456",
  "github_pr": "https://github.com/org/repo/pull/789",
  "session_id": "a1b2c3d4-...",
  "session_cwd": "/path/to/repo",
  "parent_id": "",
  "last_opened_at": "2026-03-11T16:00:00Z"
}
```
