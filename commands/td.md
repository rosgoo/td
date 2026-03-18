# td — Task Manager

You have access to `td`, a task and session manager for agentic coding. Use it to manage the user's todos.

## Current Todos

Run `td list` to see all active todos, then read the output to understand what the user is working on.

## Available Commands

```
td new "title"              # Create a new todo
td new -b "title"           # Create a backlog todo
td done <id>                # Mark a todo as done
td split <parent-id> "title" # Add a subtask under a parent todo
td note <id> "text"         # Append a note to a todo's plan.md
td link <id> <url>          # Link a Linear ticket, GitHub PR, or branch URL
td rename <id> "new title"  # Rename a todo
td delete <id> --force      # Delete a todo
td get <id>                 # Print todo as JSON (for inspecting details)
td show <id>                # Print the path to a todo's plan.md
td list                     # List all active todos
td find <query>             # Search todos by title
```

## Guidelines

- Run `td list` to discover todo IDs — IDs are human-readable slugs (e.g., `fix-document-audit`). The list shows the full hierarchy (parent → subtask tree), not a flat list.
- IDs can be shortened to a unique prefix (e.g., `td done fix-doc` instead of the full ID)
- When the user asks to create, complete, or manage tasks, use `td` commands
- Use `td note` to record important decisions or context on the current todo
- Use `td link` to attach relevant URLs (PRs, tickets, branches) to todos
- Use `td get <id>` to inspect a todo's full details (branch, worktree, links, etc.)
- Read a todo's `plan.md` (via `td show <id>`) to understand its full context. **For subtasks, also check the parent's `plan.md`** — parent plans often contain high-level context, constraints, and decisions that apply to all subtasks. Walk up the hierarchy (`td get <id>` shows `parent_id`) and read each ancestor's plan.
- Use `td split` to break large todos into subtasks when the user's work has distinct parts
- When updating a todo's `plan.md`, always use the full absolute path (e.g., `/Users/ryan/td/todo/.../plan.md`), not `~/td/...` — the Write tool does not expand `~`
