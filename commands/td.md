# td — Task Manager

You have the `td` CLI installed and available in your PATH. **Always use `td` commands to manage todos** — never read or write files in the `~/td/` directory directly. The CLI is the authoritative interface.

## Current Todo

**Before running `td list`, check your own system prompt context first.** If this session was started from a todo, your context already contains a `# Current Todo` block with the todo's title, ID, branch, links, and plan contents. Use that information directly — no need to call `td list` or `td get` for the current todo.

If there is no `# Current Todo` block in your context, run `td list` to discover active todos.

## CLI Commands

Run `td <command> --help` for full usage and flags. All commands below are non-interactive and safe to call via Bash.

- **Create:** `new`, `split`
- **Organize:** `done`, `bump`, `rename`, `delete`
- **Query:** `list`, `list --json`, `archive`, `get`, `show`
- **Plans:** `plan` (view, append, replace)
- **Link:** `link` (Linear tickets, GitHub PRs, branches, files)
- **Worktree:** `try`, `take`, `sync`
- **Admin:** `version`, `settings`

## Guidelines

- **Use the CLI, not the filesystem.** Do not read/write `~/td/todo/...` files directly. Use `td plan`, `td get`, `td show`, etc. The only exception is when you need to read a plan.md that `td show <id>` pointed you to.
- **Check context first** — your system prompt may already have `Todo ID:`, `Plan:`, `Branch:`, etc. for the current todo. Use those values directly instead of running commands to rediscover them.
- IDs are human-readable slugs (e.g., `fix-document-audit`) and can be shortened to a unique prefix (e.g., `td done fix-doc`).
- Use `td plan <id> "text"` to append important decisions or context to the current todo's plan.
- Use `td plan <id> -r <file>` to update a todo's plan from a file — useful when a plan has been written or revised externally (e.g., by planning-mcp).
- Use `td link` to attach relevant URLs (PRs, tickets) or branch names to todos.
- Use `td get <id>` to inspect a todo's full details (branch, worktree, links, etc.).
- Read a todo's plan (via `td plan <id>` or `td show <id>` then Read) to understand its full context. **For subtasks, also check the parent's plan** — parent plans often contain high-level context, constraints, and decisions that apply to all subtasks. Walk up the hierarchy (`td get <id>` shows `parent_id`).
- Use `td split` to break large todos into subtasks when the user's work has distinct parts.
