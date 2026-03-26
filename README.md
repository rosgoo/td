```
  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄
    █    █   █ █    █ █   █
    █    █   █ █    █ █   █
    █    █▄▄▄█ █▄▄▄▀  █▄▄▄█
```

Minimal task and session manager for agentic coding.

## 📑 Table of Contents

- [✨ Features](#-features)
- [🚀 Quick Start](#-quick-start)
- [📦 Installation](#-installation)
- [💻 Commands](#-commands)
- [🌳 Worktrees](#-worktrees)
- [🤖 Claude Integration](#-claude-integration)
- [⚙️ Configuration](#️-configuration)
- [📂 Data](#-data)

---

## ✨ Features

- **Session management** — links Claude sessions and working directories to tasks so you can resume exactly where you left off and reduce context overload
- **Subtasks** — break todos into smaller pieces that inherit their parent's branch, worktree, and links
- **Plan management** — each task and subtask have their own `plan.md` that gets injected into Claude's system prompt, so context carries across sessions automatically. Subtasks automatically get their parent plans injected too. Works great with Obsidian!
- **Worktree management** — spin up dedicated worktrees and leverage `td try` and `td take` for easy worktree management
- **`td do`** — create a todo and drop into a Claude session directly (run with no name to get a random NYC-inspired name)
- **`/td` slash command** — manage todos from inside any Claude Code session using the non-interactive cli commands
- **Linear & GitHub linking** — attach tickets, PRs, and branches to todos; open them from the picker
- **Pre-compact hook** — automatically snapshots conversation context into `plan.md` before Claude compacts, so notes are never lost
- **Local first** — all storage is done in markdown and json reducing dependencies

---

## 🚀 Quick Start

```bash
td do "Fix the login bug"       # Create a todo and start Claude immediately
td do                            # Same thing — suggests a random NYC name
td                               # Open the picker — select to resume the session
td done                          # Mark it as done when finished
```

Inside a Claude session, use the `/td` slash command to manage todos without leaving the conversation.

---

## 📦 Installation

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
pipx install td    # isolated install (recommended)
pip install td     # or pip
```

**From source (for development):**

```bash
git clone https://github.com/rosgoo/td.git
cd td
./dev-install.sh    # creates .venv, installs editable, links td to ~/.local/bin
```

This gives you `td` pointing to the Python dev version (editable — changes to `src/` take effect immediately).

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

## 💻 Commands

All commands accept an optional `[id]` (or ID prefix) to skip the interactive picker. This makes them usable by AI agents non-interactively.

### Interactive

| Command | Description |
|---------|-------------|
| `td` | Open the fzf picker (create or select a todo) |
| `td do ["title"]` | Create a todo and immediately open a Claude session (random name if omitted) |
| `td open [id]` | Open the action menu for a todo (resume session, link, done, etc.) |
| `td edit [id]` | Open plan.md in your editor |
| `td browse` | Open notes directory in your editor |
| `td find [query]` | Search Claude sessions, create a todo, and resume |

`td do` and `td new` support `-c <parent>` to create as a subtask under a parent todo.

### Non-interactive (AI-friendly)

| Command | Description |
|---------|-------------|
| `td new ["title"]` | Create a new todo (`-b` for backlog, `-c` for subtask) |
| `td split [id] ["title"]` | Create a subtask under a parent todo |
| `td done [id]` | Mark a todo as done (optionally cleans up worktree/branch) |
| `td list` | List active todos |
| `td archive` | Show completed todos |
| `td get <id>` | Print todo as JSON |
| `td plan <id>` | Print the plan contents |
| `td plan <id> "text"` | Append text to a todo's plan |
| `td plan <id> -r <file>` | Replace plan.md with an existing file |
| `td plan <id> -o` | Open plan.md in your editor |
| `td show [id]` | Print the absolute path to plan.md |
| `td bump [id]` | Toggle a todo between TODO and backlog |
| `td rename [id] "title"` | Rename a todo |
| `td delete [id]` | Delete a todo and all related data (notes, worktree, branch) |
| `td link [id] [url/path]` | Link a Linear ticket, branch, PR, or plan file |
| `td try [id]` | Apply worktree diff to a try branch on main repo |
| `td take [id]` | Cherry-pick try branch changes back into the worktree |
| `td sync` | Two-way sync: create/remove todos and dirs (`-n` for dry run) |

### Admin

| Command | Description |
|---------|-------------|
| `td init` | Configure settings interactively |
| `td settings` | Print the current settings file |
| `td update` | Update to latest version |
| `td version` | Print version |
| `td help` | Show help |

### 🔗 Linking

`td link` auto-detects the type from the input:

```bash
td link abc123 https://linear.app/team/CORE-456       # Linear ticket
td link abc123 https://github.com/org/repo/pull/789   # GitHub PR
td link abc123 https://github.com/org/repo/tree/feat  # Git branch
td link abc123 ~/vault/my-notes.md                    # External notes file
```

### 🧩 Subtasks

Subtasks inherit their parent's branch, worktree, and Linear ticket. Metadata that matches the parent is deduplicated in the picker view.

```bash
td split abc123 "Write tests"       # Add a subtask under abc123
td new "Write tests" -c abc123      # Same thing
td do "Write tests" -c abc123       # Create subtask and start Claude
```

### 🔄 Sync

```bash
td sync       # Two-way sync: create todos for orphaned dirs, remove todos for missing dirs
td sync -n    # Dry run — show what would happen without making changes
```

If you create a folder in `~/td/todo/` manually (e.g. from Obsidian), `td sync` picks it up and creates a todo for it. If you delete a folder, `td sync` removes the orphaned todo. Nested subdirectories become subtasks automatically.

---

## 🌳 Worktrees

Todos can optionally use [git worktrees](https://git-scm.com/docs/git-worktree) for branch isolation. When you choose "Start Claude (new worktree)" from the picker, a worktree is created at `.claude/worktrees/<slug>` with a branch named `todo/<slug>`.

This keeps each task's changes on a separate branch in a separate directory, so you can work on multiple things without stashing or switching branches in your main repo.

### `td try` — push changes out for testing

Use `td try` to test worktree changes on your main repo without leaving the worktree. It diffs all changes from the worktree branch against main and applies them as a single commit on a `try-<slug>` branch in the main repo.

This avoids the pain of switching back to main just to test — no reinstalling dependencies, no rebuilding, no restarting dev servers. Your worktree stays untouched while you can run the full test suite or start the app from the main repo on the try branch.

```bash
td try           # pick a todo from the picker
td try abc123    # or pass an ID directly
```

### `td take` — pull changes back from try

After testing on the try branch, you may have made fixes or adjustments (manually or via Claude). Use `td take` to bring those changes back into the worktree.

It finds commits made on the `try-<slug>` branch after the initial `td try` commit and cherry-picks them into the worktree branch. Only the new work comes back — the original changes that were already in the worktree are skipped.

```bash
td take          # pick a todo from the picker
td take abc123   # or pass an ID directly
```

After a successful take, you're prompted to delete the try branch to keep things clean.

### Typical workflow

```
worktree (todo/my-feature)          main repo
        |                                |
        |--- td try --->  try-my-feature (changes applied)
        |                       |
        |                    fix tests, adjust code
        |                       |
        |<-- td take ---  cherry-pick fixes back
        |
     continue working
```

### Worktree setup script

Use the `worktree_script` setting to run a shell command automatically after a new worktree is created. The command runs with its working directory set to the new worktree, so you can install dependencies, copy environment files, or do any other setup.

Configure it in `~/.config/claude-todo/settings.json`:

```json
{
  "worktree_script": "cp ../.env .env && npm install"
}
```

Or set via the environment variable:

```bash
export TODO_WORKTREE_SCRIPT="cp ../.env .env && npm install"
```

This is useful when each worktree needs its own `node_modules`, virtual environment, or config files that aren't tracked by git.

### Lifecycle

- **Done** — `td done` optionally cleans up the worktree and branch
- **Delete** — `td delete` removes the worktree, branch, notes, and todo record

---

## 🤖 Claude Integration

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

## ⚙️ Configuration

Run `td init` to configure settings interactively. Run `td settings` to view the current settings file.

```bash
td init
```

This walks you through each setting:

```
  data_dir — Where todos and notes are stored
  Current: ~/td

  editor — Editor for opening plan.md files
  Examples: "code", "nvim", "obsidian"
  Current: (auto-detect)

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
  "branch_prefix": "todo",
  "worktree_script": ""
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `data_dir` | Where todos and notes are stored | `~/td` |
| `repo` | Git repo root override — leave empty to auto-detect via `git rev-parse`. Useful if you work from a subdirectory or worktree and want to pin the repo root explicitly. | _(auto-detect)_ |
| `editor` | Editor for notes | `open` (macOS) / `vi` |
| `linear_org` | Linear organization slug (for ticket URLs) | _(disabled)_ |
| `worktree_dir` | Worktree directory relative to repo root | `.claude/worktrees` |
| `branch_prefix` | Prefix for auto-created branches | `todo` |
| `worktree_script` | Shell command to run after creating a worktree (runs with cwd set to the new worktree) | _(disabled)_ |

Environment variables override settings: `TODO_DATA_DIR`, `TODO_REPO`, `TODO_EDITOR`, `TODO_LINEAR_ORG`, `TODO_WORKTREE_DIR`, `TODO_BRANCH_PREFIX`, `TODO_WORKTREE_SCRIPT`.

---

## 📂 Data

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
