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

- IDs can be shortened to a unique prefix (e.g., `td done 177` instead of the full ID)
- When the user asks to create, complete, or manage tasks, use `td` commands
- Use `td note` to record important decisions or context on the current todo
- Use `td link` to attach relevant URLs (PRs, tickets, branches) to todos
- Use `td get <id>` to inspect a todo's full details (branch, worktree, links, etc.)
- Read a todo's `plan.md` (via `td show <id>`) to understand its full context
- Use `td split` to break large todos into subtasks when the user's work has distinct parts
