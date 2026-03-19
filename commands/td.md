# td — Task Manager

You have access to `td`, a task and session manager for agentic coding. Use it to manage the user's todos.

## Current Todo

**Before running `td list`, check your own system prompt context first.** If this session was started from a todo, your context already contains a `# Current Todo` block with the todo's title, ID, branch, links, and plan contents. Use that information directly — no need to call `td list` or `td get` for the current todo.

If there is no `# Current Todo` block in your context, run `td list` to discover active todos.

## Available Commands

```
td new "title"              # Create a new todo
td new -b "title"           # Create a backlog todo
td new -c <parent> "title"  # Create a subtask under a parent todo
td do "title"               # Create a todo and start Claude immediately
td do -c <parent> "title"   # Create a subtask and start Claude immediately
td done <id>                # Mark a todo as done
td split <parent-id> "title" # Add a subtask under a parent todo
td plan <id>                # Print the plan contents
td plan <id> "text"         # Append text to a todo's plan.md
td plan <id> -r <file>      # Replace plan.md with an existing file
td plan <id> -o             # Open plan.md in your editor
td link <id> <url|branch>   # Link a Linear ticket, GitHub PR, branch name, or file
td rename <id> "new title"  # Rename a todo
td delete <id> --force      # Delete a todo
td get <id>                 # Print todo as JSON (for inspecting details)
td show <id>                # Print the path to a todo's plan.md
td bump <id>                # Toggle a todo between TODO and backlog
td list                     # List all active todos
td try <id>                 # Apply worktree diff to a try branch on main repo
td take <id>                # Cherry-pick try branch changes back into worktree
td find <query>             # Search Claude sessions, create a todo, and resume
```

## Guidelines

- **Check context first** — your system prompt may already have `Todo ID:`, `Plan:`, `Branch:`, etc. for the current todo. Use those values directly instead of running commands to rediscover them.
- Run `td list` to discover todo IDs — IDs are human-readable slugs (e.g., `fix-document-audit`). The list shows the full hierarchy (parent → subtask tree), not a flat list.
- IDs can be shortened to a unique prefix (e.g., `td done fix-doc` instead of the full ID)
- When the user asks to create, complete, or manage tasks, use `td` commands
- Use `td plan <id> "text"` to append important decisions or context to the current todo's plan
- Use `td plan <id> --replace <file>` to update a todo's plan from a file — useful when a plan has been written or revised externally (e.g., by planning-mcp) and you want to copy it into the todo's plan.md
- Use `td link` to attach relevant URLs (PRs, tickets) or branch names to todos — accepts Linear URLs, GitHub PR/branch URLs, local branch names (e.g. `feature/my-branch`), or file paths
- Use `td get <id>` to inspect a todo's full details (branch, worktree, links, etc.)
- Read a todo's `plan.md` (via `td show <id>`) to understand its full context. **For subtasks, also check the parent's `plan.md`** — parent plans often contain high-level context, constraints, and decisions that apply to all subtasks. Walk up the hierarchy (`td get <id>` shows `parent_id`) and read each ancestor's plan.
- Use `td split` to break large todos into subtasks when the user's work has distinct parts
- When updating a todo's `plan.md`, always use the full absolute path (e.g., `/Users/ryan/td/todo/.../plan.md`), not `~/td/...` — the Write tool does not expand `~`
