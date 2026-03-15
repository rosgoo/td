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
- **`td do`** — create a todo and drop into a Claude session directly
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
td                               # Open the picker — select to resume the session
td done                          # Mark it as done when finished
```

Inside a Claude session, use the `/td` slash command to manage todos without leaving the conversation.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rosgoo/td/main/install-remote.sh | bash
```

This downloads the latest release, installs dependencies via Homebrew, and sets up the Claude Code hook and `/td` slash command. Make sure `~/.local/bin` is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

To update:

```bash
td update
```

### Other install methods

**Homebrew:**

```bash
brew install rosgoo/tap/td
```

**From source (for development):**

```bash
git clone https://github.com/rosgoo/td.git
cd td
./install.sh
```

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

### Dependencies

| Tool | Purpose |
|------|---------|
| [jq](https://github.com/stedolan/jq) | JSON processing |
| [fzf](https://github.com/junegunn/fzf) | Fuzzy picker |
| [gum](https://github.com/charmbracelet/gum) | Interactive prompts |
| [Claude Code](https://claude.ai/code) | AI coding sessions |

---

## Commands

All commands accept an optional `[id]` (or ID prefix) to skip the interactive picker. This makes them usable by AI agents non-interactively.

### Core

| Command | Description |
|---------|-------------|
| `td` | Open the fzf picker (create or select a todo) |
| `td new "title"` | Create a new todo |
| `td do "title"` | Create a todo and immediately open a Claude session |
| `td done [id]` | Mark a todo as done (optionally cleans up worktree/branch) |
| `td rename [id] "title"` | Rename a todo |
| `td delete [id]` | Delete a todo and all related data (notes, worktree, branch) |
| `td list` | List all active todos |
| `td archive` | Show completed todos |

### Notes

| Command | Description |
|---------|-------------|
| `td edit [id]` | Open notes in your editor |
| `td note <id> "text"` | Append text to a todo's notes (non-interactive) |
| `td show [id]` | Print the absolute path to plan.md |

### Linking

| Command | Description |
|---------|-------------|
| `td link [id] [url/path]` | Link a Linear ticket, GitHub URL, or notes file |
| `td open` | Open Linear ticket or GitHub branch/PR in browser |
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
td note abc123 "Decided to use JWT instead of sessions"
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

For example, to use **Obsidian** as your notes editor, set `editor` to `open -a Obsidian`. This opens plan.md files directly in your Obsidian vault — useful if your `data_dir` is inside an Obsidian vault (e.g. `~/vault/td`).

Settings are saved to `~/.config/claude-todo/settings.json`:

```json
{
  "data_dir": "~/td",
  "repo": "",
  "editor": "open -a Obsidian",
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
  notes/
    <id>/plan.md          # Notes for each todo (+ session notes appended by hooks)
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
  "notes_path": "~/td/notes/1773202250-266f62/plan.md",
  "linear_ticket": "CORE-456",
  "github_pr": "https://github.com/org/repo/pull/789",
  "session_id": "a1b2c3d4-...",
  "session_cwd": "/path/to/repo",
  "parent_id": "",
  "last_opened_at": "2026-03-11T16:00:00Z"
}
```
