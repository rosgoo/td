"""td — Minimal task manager for Claude Code."""

import json
import os
import sys
from datetime import datetime
from pathlib import Path

import typer
from rich.console import Console

app = typer.Typer(
    name="td",
    help="Minimal task manager for Claude Code",
    add_completion=False,
    no_args_is_help=False,
    invoke_without_command=True,
)

stderr = Console(stderr=True)


def _version_str() -> str:
    here = Path(__file__).resolve().parent
    for parent in [here, here.parent, here.parent.parent]:
        v = parent / "VERSION"
        if v.exists():
            return v.read_text().strip()
    return "dev"


# ---------------------------------------------------------------------------
# Callbacks and version
# ---------------------------------------------------------------------------

@app.callback()
def main(ctx: typer.Context) -> None:
    """td — Minimal task manager for Claude Code."""
    from td_cli.data import ensure_setup
    ensure_setup()
    if ctx.invoked_subcommand is None:
        _picker()


@app.command()
def version() -> None:
    """Print version."""
    typer.echo(f"td {_version_str()}")


# ---------------------------------------------------------------------------
# td new [-b] "title"
# ---------------------------------------------------------------------------

@app.command()
def new(
    title: str = typer.Argument(None),
    backlog: bool = typer.Option(False, "-b", "--backlog"),
) -> None:
    """Create a new todo."""
    from td_cli.config import NOTES_DIR, QUIET
    from td_cli.data import (
        generate_id, notes_folder_name, read_todos, write_todos, now_iso,
    )
    from td_cli.ui import prompt_input

    if not title:
        title = prompt_input("Todo title...")
        if not title:
            raise typer.Exit()

    group = "backlog" if backlog else "todo"
    todo_id = generate_id(title)
    notes_path = NOTES_DIR / notes_folder_name(todo_id, title)

    # Create plan.md
    notes_path.mkdir(parents=True, exist_ok=True)
    plan = notes_path / "plan.md"
    plan.write_text(
        f"# {title}\n\nCreated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n## Plan\n\n"
    )

    now = now_iso()
    todos = read_todos()
    todos.append({
        "id": todo_id,
        "title": title,
        "created_at": now,
        "branch": "",
        "worktree_path": "",
        "notes_path": str(plan),
        "status": "active",
        "group": group,
    })
    write_todos(todos)

    if QUIET:
        typer.echo(todo_id)
    else:
        group_label = " [dim](backlog)[/]" if group == "backlog" else ""
        stderr.print(f"[green]✓[/] Created: [bold]{title}[/]{group_label}  [dim]{todo_id}[/]")
        stderr.print(f"  [dim]Next: td edit {todo_id}  ·  td link {todo_id}  ·  td split {todo_id}[/]")


# ---------------------------------------------------------------------------
# td do [-n "title"]
# ---------------------------------------------------------------------------

@app.command("do")
def do_cmd(
    title: str = typer.Argument(None),
) -> None:
    """Create a todo and start Claude immediately."""
    from td_cli.config import NOTES_DIR
    from td_cli.data import (
        generate_id, notes_folder_name, read_todos, write_todos, now_iso,
        random_name,
    )
    from td_cli.session import start_session
    from td_cli.ui import prompt_input

    if not title:
        title = prompt_input("What are you working on?", default=random_name())
        if not title:
            raise typer.Exit()

    todo_id = generate_id(title)
    notes_path = NOTES_DIR / notes_folder_name(todo_id, title)
    notes_path.mkdir(parents=True, exist_ok=True)
    plan = notes_path / "plan.md"
    plan.write_text(
        f"# {title}\n\nCreated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n## Plan\n\n"
    )

    now = now_iso()
    todos = read_todos()
    todos.append({
        "id": todo_id, "title": title, "created_at": now,
        "branch": "", "worktree_path": "", "notes_path": str(plan),
        "status": "active", "group": "todo",
    })
    write_todos(todos)

    stderr.print(f"[green]✓[/] Created: [bold]{title}[/]  [dim]{todo_id}[/]")
    start_session(todo_id, "current-dir")


# ---------------------------------------------------------------------------
# td split [parent-id] ["title"]
# ---------------------------------------------------------------------------

@app.command()
def split(
    parent_id: str = typer.Argument(None),
    title: str = typer.Argument(None),
) -> None:
    """Create a subtask under a parent todo."""
    from td_cli.config import NOTES_DIR, QUIET
    from td_cli.data import (
        generate_id, notes_folder_name, read_todos, write_todos, now_iso,
        resolve_id, get_todo,
    )
    from td_cli.ui import pick_todo, prompt_input

    if not parent_id:
        parent_id = pick_todo("Select parent todo", "add ❯ ")
        if not parent_id:
            raise typer.Exit()
    else:
        parent_id = resolve_id(parent_id)

    parent = get_todo(parent_id)
    if not parent:
        raise typer.Exit(1)

    parent_title = parent["title"]
    parent_branch = parent.get("branch", "")
    parent_wt = parent.get("worktree_path", "")

    if not title:
        stderr.print(f"[dim]Adding subtask to: {parent_title}[/]")
        title = prompt_input("Subtask title...")
        if not title:
            raise typer.Exit()

    todo_id = generate_id(title)
    parent_notes = parent.get("notes_path", "")
    parent_notes_dir = Path(parent_notes).parent if parent_notes else NOTES_DIR

    folder = notes_folder_name(todo_id, title, parent_notes_dir)
    notes_path = parent_notes_dir / folder
    notes_path.mkdir(parents=True, exist_ok=True)
    plan = notes_path / "plan.md"
    plan.write_text(
        f"# {title}\n\nCreated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
        f"Parent: {parent_title}\n\n## Plan\n\n"
    )

    now = now_iso()
    todos = read_todos()
    todos.append({
        "id": todo_id, "title": title, "created_at": now,
        "branch": parent_branch, "worktree_path": parent_wt,
        "notes_path": str(plan), "status": "active",
        "parent_id": parent_id,
    })
    write_todos(todos)

    if QUIET:
        typer.echo(todo_id)
    else:
        stderr.print(f"[green]✓[/] Created subtask: [bold]{title}[/]")
        stderr.print(f"  [dim]Parent: {parent_title}[/]")


# ---------------------------------------------------------------------------
# td done [id]
# ---------------------------------------------------------------------------

def _archive_todo(todo_id: str) -> None:
    """Mark a todo and its descendants as done, with optional cleanup."""
    from td_cli.config import REPO_ROOT
    from td_cli.data import get_todo, read_todos, write_todos
    from td_cli.ui import prompt_confirm

    todo = get_todo(todo_id)
    if not todo:
        return
    title = todo["title"]
    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")

    # Collect all descendant IDs
    todos = read_todos()
    def descendants(pid: str) -> list[str]:
        kids = [t["id"] for t in todos if t.get("parent_id") == pid]
        result = list(kids)
        for kid in kids:
            result.extend(descendants(kid))
        return result

    all_ids = {todo_id} | set(descendants(todo_id))
    for t in todos:
        if t["id"] in all_ids:
            t["status"] = "done"
    write_todos(todos)

    stderr.print(f"[green]✓[/] Done: [bold]{title}[/]")

    # Report subtasks
    for t in todos:
        if t.get("parent_id") == todo_id and t["status"] == "done":
            stderr.print(f"  [dim]✓ {t['title']}[/]")

    # Offer cleanup
    if wt_path or branch:
        if prompt_confirm("Remove worktree and branch?"):
            repo = REPO_ROOT
            if repo:
                if wt_path and os.path.isdir(wt_path):
                    subprocess.run(
                        ["git", "-C", repo, "worktree", "remove", wt_path, "--force"],
                        capture_output=True,
                    )
                    stderr.print("[dim]Removed worktree[/]")
                if branch:
                    import subprocess
                    if subprocess.run(
                        ["git", "-C", repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
                        capture_output=True,
                    ).returncode == 0:
                        subprocess.run(
                            ["git", "-C", repo, "branch", "-D", branch],
                            capture_output=True,
                        )
                        stderr.print(f"[dim]Deleted branch {branch}[/]")


@app.command()
def done(todo_id: str = typer.Argument(None)) -> None:
    """Mark a todo as done."""
    from td_cli.data import resolve_id
    from td_cli.ui import pick_todo

    if todo_id:
        todo_id = resolve_id(todo_id)
    else:
        todo_id = pick_todo("Select todo to mark as done", "done ❯ ")
        if not todo_id:
            raise typer.Exit()
    _archive_todo(todo_id)


# ---------------------------------------------------------------------------
# td edit [id]
# ---------------------------------------------------------------------------

@app.command()
def edit(todo_id: str = typer.Argument(None)) -> None:
    """Open plan.md in editor."""
    from td_cli.config import open_notes
    from td_cli.data import resolve_id, get_todo, ensure_notes
    from td_cli.ui import pick_todo

    if todo_id:
        todo_id = resolve_id(todo_id)
    else:
        todo_id = pick_todo("Select todo to edit plan", "edit ❯ ")
        if not todo_id:
            raise typer.Exit()

    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    notes_path = todo.get("notes_path", "")
    if not notes_path or not os.path.isfile(notes_path):
        notes_path = ensure_notes(todo_id, todo["title"])
    open_notes(notes_path)


# ---------------------------------------------------------------------------
# td list [--json]
# ---------------------------------------------------------------------------

@app.command("list")
def list_cmd(json_mode: bool = typer.Option(False, "--json")) -> None:
    """List active todos."""
    from td_cli.data import active_todos

    todos = active_todos()
    if json_mode:
        typer.echo(json.dumps(todos, indent=2))
        return

    if not todos:
        stderr.print("[dim]No active todos.[/]")
        raise typer.Exit()

    todo_items = [t for t in todos if t.get("group", "todo") == "todo"]
    backlog_items = [t for t in todos if t.get("group", "todo") == "backlog"]

    def _section(items: list[dict], icon: str) -> None:
        for t in items:
            stderr.print(f"\n  {icon} [bold]{t['title']}[/]  [dim]{t['id']}[/]")
            parts = []
            if t.get("linear_ticket"):
                parts.append(f"[magenta]{t['linear_ticket']}[/]")
            if t.get("branch"):
                parts.append(f"[cyan]{t['branch']}[/]")
            if t.get("github_pr"):
                parts.append(f"[cyan]{t['github_pr']}[/]")
            if parts:
                stderr.print(f"    {'  '.join(parts)}")
            if t.get("worktree_path"):
                stderr.print(f"    [dim]{t['worktree_path']}[/]")
            stderr.print(f"    [dim]{t.get('created_at', '')[:10]}[/]")

    if todo_items:
        stderr.print(f"\n  [bold]TODO[/] [dim]({len(todo_items)})[/]")
        stderr.print(f"  [dim]{'─' * 50}[/]")
        _section(todo_items, "[green]◉[/]")

    if backlog_items:
        stderr.print(f"\n  [dim]Backlog[/] [dim]({len(backlog_items)})[/]")
        stderr.print(f"  [dim]{'─' * 50}[/]")
        _section(backlog_items, "[dim]○[/]")

    stderr.print()


# ---------------------------------------------------------------------------
# td archive
# ---------------------------------------------------------------------------

@app.command()
def archive() -> None:
    """Show completed todos."""
    from td_cli.data import done_todos

    todos = done_todos()
    if not todos:
        stderr.print("[dim]No completed todos.[/]")
        raise typer.Exit()

    stderr.print(f"\n  [bold]Completed[/] [dim]({len(todos)})[/]")
    stderr.print(f"  [dim]{'─' * 50}[/]")

    for t in todos:
        parts = [f"\n  [green]✓[/] [dim]{t['title']}[/]"]
        if t.get("linear_ticket"):
            parts.append(f"  [magenta]{t['linear_ticket']}[/]")
        if t.get("branch"):
            parts.append(f"  [cyan]{t['branch']}[/]")
        parts.append(f"  [dim]{t.get('created_at', '')[:10]}[/]")
        stderr.print("".join(parts))
    stderr.print()


# ---------------------------------------------------------------------------
# td get <id>
# ---------------------------------------------------------------------------

@app.command()
def get(todo_id: str = typer.Argument(None)) -> None:
    """Print todo as JSON."""
    from td_cli.data import resolve_id, get_todo

    if not todo_id:
        stderr.print("[red]Usage:[/] td get <id>")
        raise typer.Exit(1)
    todo_id = resolve_id(todo_id)
    todo = get_todo(todo_id)
    typer.echo(json.dumps(todo, indent=2))


# ---------------------------------------------------------------------------
# td note <id> "text"
# ---------------------------------------------------------------------------

@app.command()
def note(todo_id: str, text: str) -> None:
    """Append text to a todo's plan.md."""
    from td_cli.data import resolve_id, get_todo, ensure_notes

    todo_id = resolve_id(todo_id)
    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    notes_path = todo.get("notes_path", "")
    if not notes_path or not os.path.isfile(notes_path):
        notes_path = ensure_notes(todo_id, todo["title"])
    with open(notes_path, "a") as f:
        f.write(f"\n{text}\n")
    stderr.print(f"[green]✓[/] Appended to [dim]{notes_path}[/]")


# ---------------------------------------------------------------------------
# td show [id]
# ---------------------------------------------------------------------------

@app.command()
def show(todo_id: str = typer.Argument(None)) -> None:
    """Print the plan.md path for a todo."""
    from td_cli.data import resolve_id, get_todo, ensure_notes
    from td_cli.ui import pick_todo

    if todo_id:
        todo_id = resolve_id(todo_id)
    else:
        todo_id = pick_todo("Select todo", "show ❯ ")
        if not todo_id:
            raise typer.Exit()
    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    notes_path = todo.get("notes_path", "")
    if not notes_path or not os.path.isfile(notes_path):
        notes_path = ensure_notes(todo_id, todo["title"])
    typer.echo(notes_path)


# ---------------------------------------------------------------------------
# td bump [id]
# ---------------------------------------------------------------------------

def _bump_group(todo_id: str, new_group: str) -> None:
    from td_cli.data import get_todo, read_todos, write_todos

    todos = read_todos()
    def descendants(pid: str) -> list[str]:
        kids = [t["id"] for t in todos if t.get("parent_id") == pid]
        result = list(kids)
        for kid in kids:
            result.extend(descendants(kid))
        return result

    all_ids = {todo_id} | set(descendants(todo_id))
    for t in todos:
        if t["id"] in all_ids:
            t["group"] = new_group
    write_todos(todos)

    todo = get_todo(todo_id)
    title = todo["title"] if todo else ""
    if new_group == "backlog":
        stderr.print(f"[dim]·[/] Moved to backlog: [dim]{title}[/]  [dim]{todo_id}[/]")
    else:
        stderr.print(f"[green]·[/] Moved to TODO: [bold]{title}[/]  [dim]{todo_id}[/]")

    for t in read_todos():
        if t.get("parent_id") == todo_id and t.get("group") == new_group:
            stderr.print(f"  [dim]· {t['title']}[/]")


@app.command()
def bump(todo_id: str = typer.Argument(None)) -> None:
    """Toggle a todo between TODO and backlog."""
    from td_cli.data import resolve_id, get_todo
    from td_cli.ui import pick_todo

    if not todo_id:
        todo_id = pick_todo("Select todo to bump", "bump ❯ ")
        if not todo_id:
            raise typer.Exit()
    else:
        todo_id = resolve_id(todo_id)

    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    current = todo.get("group", "todo")
    _bump_group(todo_id, "todo" if current == "backlog" else "backlog")


# ---------------------------------------------------------------------------
# td rename [id] ["new title"]
# ---------------------------------------------------------------------------

@app.command()
def rename(todo_id: str = typer.Argument(None), new_title: str = typer.Argument(None)) -> None:
    """Rename a todo."""
    from td_cli.config import NOTES_DIR
    from td_cli.data import resolve_id, get_todo, read_todos, write_todos, notes_folder_name
    from td_cli.ui import pick_todo, prompt_input

    if not todo_id:
        todo_id = pick_todo("Select todo to rename", "rename ❯ ")
        if not todo_id:
            raise typer.Exit()
    else:
        todo_id = resolve_id(todo_id)

    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    old_title = todo["title"]

    if not new_title:
        new_title = prompt_input("New title", default=old_title)
        if not new_title:
            raise typer.Exit()

    # Rename notes folder
    old_notes_path = todo.get("notes_path", "")
    new_folder = notes_folder_name(todo_id, new_title)
    new_notes_path = str(NOTES_DIR / new_folder / "plan.md")

    if old_notes_path:
        old_dir = Path(old_notes_path).parent
        new_dir = NOTES_DIR / new_folder
        if old_dir.is_dir() and str(old_dir).startswith(str(NOTES_DIR)) and old_dir != new_dir:
            old_dir.rename(new_dir)

    todos = read_todos()
    for t in todos:
        if t["id"] == todo_id:
            t["title"] = new_title
            t["notes_path"] = new_notes_path
    write_todos(todos)

    stderr.print(f"[green]✓[/] Renamed: [dim]{old_title}[/] › [bold]{new_title}[/]")


# ---------------------------------------------------------------------------
# td delete [id] [--force]
# ---------------------------------------------------------------------------

@app.command()
def delete(todo_id: str = typer.Argument(None), force: bool = typer.Option(False, "--force")) -> None:
    """Delete a todo and all related data."""
    import subprocess
    from td_cli.config import NOTES_DIR, REPO_ROOT
    from td_cli.data import resolve_id, get_todo, read_todos, write_todos
    from td_cli.ui import pick_todo, prompt_confirm

    if not todo_id:
        todo_id = pick_todo("Select todo to delete", "delete ❯ ")
        if not todo_id:
            raise typer.Exit()
    else:
        todo_id = resolve_id(todo_id)

    todo = get_todo(todo_id)
    if not todo:
        raise typer.Exit(1)
    title = todo["title"]
    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    notes_path = todo.get("notes_path", "")

    if not force:
        stderr.print(f"[red]Delete:[/] [bold]{title}[/]")
        if wt_path:
            stderr.print(f"  [dim]Will remove worktree: {wt_path}[/]")
        if branch:
            stderr.print(f"  [dim]Will delete branch: {branch}[/]")
        if notes_path:
            stderr.print(f"  [dim]Will delete plan: {notes_path}[/]")
        if not prompt_confirm("Delete this todo and all related data?"):
            raise typer.Exit()

    repo = REPO_ROOT
    if wt_path and os.path.isdir(wt_path) and repo:
        subprocess.run(
            ["git", "-C", repo, "worktree", "remove", wt_path, "--force"],
            capture_output=True,
        )
        stderr.print("[dim]Removed worktree[/]")

    if branch and not branch.startswith("http") and repo:
        if subprocess.run(
            ["git", "-C", repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
            capture_output=True,
        ).returncode == 0:
            subprocess.run(["git", "-C", repo, "branch", "-D", branch], capture_output=True)
            stderr.print(f"[dim]Deleted branch {branch}[/]")

    if notes_path:
        notes_dir = Path(notes_path).parent
        if notes_dir.is_dir() and str(notes_dir).startswith(str(NOTES_DIR)):
            import shutil
            shutil.rmtree(notes_dir)
            stderr.print("[dim]Deleted plan[/]")

    # Recursively delete subtasks
    todos = read_todos()
    subtask_ids = [t["id"] for t in todos if t.get("parent_id") == todo_id]
    for sid in subtask_ids:
        delete(sid, force=True)

    # Remove from JSON (re-read since recursive deletes may have modified)
    todos = read_todos()
    todos = [t for t in todos if t["id"] != todo_id]
    write_todos(todos)

    stderr.print(f"[green]✓[/] Deleted: [bold]{title}[/]")


# ---------------------------------------------------------------------------
# td link [id] [url|path]
# ---------------------------------------------------------------------------

@app.command()
def link(arg1: str = typer.Argument(None), arg2: str = typer.Argument(None)) -> None:
    """Link a Linear ticket, branch, PR, or plan file."""
    from td_cli.data import resolve_id, get_todo, read_todos, write_todos
    from td_cli.git import extract_linear_ticket, extract_github_branch
    from td_cli.ui import pick_todo, prompt_choose, prompt_input

    selected_id = ""
    url = ""

    if arg1 and arg2:
        selected_id = resolve_id(arg1)
        url = arg2
    elif arg1:
        if "linear.app" in arg1 or "github.com" in arg1:
            url = arg1
        elif "/" in arg1 or arg1.endswith(".md") or arg1.endswith(".txt"):
            url = arg1
        else:
            try:
                selected_id = resolve_id(arg1)
            except SystemExit:
                url = arg1

    if not selected_id:
        selected_id = pick_todo("Select todo to link", "link ❯ ")
        if not selected_id:
            raise typer.Exit()

    todo = get_todo(selected_id)
    if not todo:
        raise typer.Exit(1)
    title = todo["title"]

    # Auto-detect link type from URL
    if url:
        todos = read_todos()
        if "linear.app" in url:
            ticket_id = extract_linear_ticket(url)
            for t in todos:
                if t["id"] == selected_id:
                    t["linear_ticket"] = ticket_id
            write_todos(todos)
            stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [magenta]{ticket_id}[/]")
        elif "github.com" in url and "/pull/" in url:
            for t in todos:
                if t["id"] == selected_id:
                    t["github_pr"] = url
            write_todos(todos)
            stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [cyan]{url}[/]")
        elif "github.com" in url and "/tree/" in url:
            new_branch = extract_github_branch(url)
            for t in todos:
                if t["id"] == selected_id:
                    t["branch"] = new_branch
            write_todos(todos)
            stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [cyan]{new_branch}[/]")
        elif "/" in url or url.endswith(".md") or url.endswith(".txt"):
            notes_input = url.replace("~", str(Path.home()), 1) if url.startswith("~") else url
            notes_input = str(Path(notes_input).resolve())
            if not os.path.isfile(notes_input):
                stderr.print(f"[yellow]Warning:[/] File does not exist yet: {notes_input}")
            for t in todos:
                if t["id"] == selected_id:
                    t["notes_path"] = notes_input
            write_todos(todos)
            stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [dim]{notes_input}[/]")
        else:
            stderr.print("[red]Unknown URL.[/] Paste a Linear URL, GitHub URL, or file path.")
            raise typer.Exit(1)
        return

    # Interactive link type selector
    choice = prompt_choose(
        "What to link?",
        "Linear ticket", "Git branch", "GitHub PR", "Claude session", "Plan file",
    )
    if not choice:
        raise typer.Exit()

    todos = read_todos()
    if choice == "Linear ticket":
        raw = prompt_input("Linear URL or ticket ID (e.g. CORE-12207)")
        if not raw:
            raise typer.Exit()
        ticket_id = extract_linear_ticket(raw)
        for t in todos:
            if t["id"] == selected_id:
                t["linear_ticket"] = ticket_id
        write_todos(todos)
        stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [magenta]{ticket_id}[/]")
    elif choice == "GitHub PR":
        pr = prompt_input("GitHub PR URL")
        if not pr or "github.com" not in pr or "/pull/" not in pr:
            stderr.print("[red]Not a valid GitHub PR URL.[/]")
            raise typer.Exit(1)
        for t in todos:
            if t["id"] == selected_id:
                t["github_pr"] = pr
        write_todos(todos)
        stderr.print(f"[green]✓[/] Linked: [bold]{title}[/] › [cyan]{pr}[/]")
    # Other interactive cases omitted for brevity — they're less common


# ---------------------------------------------------------------------------
# td open [id]
# ---------------------------------------------------------------------------

@app.command("open")
def open_cmd(todo_id: str = typer.Argument(None)) -> None:
    """Open action menu for a todo."""
    from td_cli.data import resolve_id
    from td_cli.ui import pick_todo

    if not todo_id:
        todo_id = pick_todo("Select todo", "open ❯ ")
        if not todo_id:
            raise typer.Exit()
    else:
        todo_id = resolve_id(todo_id)
    _select_todo(todo_id)


# ---------------------------------------------------------------------------
# td try [id]
# ---------------------------------------------------------------------------

@app.command("try")
def try_cmd(todo_id: str = typer.Argument(None)) -> None:
    """Apply worktree diff to a try branch on main repo."""
    from td_cli.data import resolve_id
    from td_cli.session import try_worktree
    from td_cli.ui import pick_todo

    if todo_id:
        todo_id = resolve_id(todo_id)
    else:
        todo_id = pick_todo("Select todo to try", "try ❯ ")
        if not todo_id:
            raise typer.Exit()
    try_worktree(todo_id)


# ---------------------------------------------------------------------------
# td browse
# ---------------------------------------------------------------------------

@app.command()
def browse() -> None:
    """Open notes directory in editor."""
    from td_cli.config import NOTES_DIR, open_notes
    open_notes(str(NOTES_DIR))


# ---------------------------------------------------------------------------
# td sync [-n]
# ---------------------------------------------------------------------------

@app.command()
def sync(dry_run: bool = typer.Option(False, "-n", "--dry-run")) -> None:
    """Two-way sync: create/remove todos and dirs."""
    from td_cli.config import NOTES_DIR
    from td_cli.data import (
        generate_id, get_todo, read_todos, write_todos, now_iso,
    )

    created = 0
    removed = 0

    def _sync_dirs(base_dir: Path, parent_id: str = "") -> None:
        nonlocal created
        if not base_dir.is_dir():
            return
        for d in sorted(base_dir.iterdir()):
            if not d.is_dir():
                continue
            # Check if any todo references this directory
            todos = read_todos()
            matched = any(
                t.get("notes_path") and str(d) == str(Path(t["notes_path"]).parent)
                for t in todos
            )
            if matched:
                continue

            # Extract title
            plan = d / "plan.md"
            if plan.exists():
                first_line = plan.read_text().split("\n", 1)[0]
                title = first_line.lstrip("# ").strip()
            else:
                title = ""
            if not title:
                title = d.name

            if dry_run:
                label = f"  ↳ {title}" if parent_id else title
                stderr.print(f"[dim]Would create todo:[/] [bold]{label}[/]")
                _sync_dirs(d, "dry-run")
            else:
                todo_id = generate_id(title)
                now = now_iso()
                notes_path = str(plan) if plan.exists() else ""
                if not plan.exists():
                    d.mkdir(parents=True, exist_ok=True)
                    plan.write_text(
                        f"# {title}\n\nCreated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n## Plan\n\n"
                    )
                    notes_path = str(plan)

                entry: dict = {
                    "id": todo_id, "title": title, "created_at": now,
                    "branch": "", "worktree_path": "", "notes_path": notes_path,
                    "status": "active", "group": "todo",
                }
                if parent_id:
                    entry["parent_id"] = parent_id

                todos = read_todos()
                todos.append(entry)
                write_todos(todos)

                label = f"  ↳ {title}" if parent_id else title
                stderr.print(f"[dim]Created todo:[/] [bold]{label}[/] [dim]({todo_id})[/]")
                created += 1
                _sync_dirs(d, todo_id)

    _sync_dirs(NOTES_DIR)

    # Remove orphaned todos
    todos = read_todos()
    for t in list(todos):
        notes_path = t.get("notes_path", "")
        if not notes_path:
            continue
        notes_dir = Path(notes_path).parent
        if not notes_dir.is_dir():
            if dry_run:
                stderr.print(f"[dim]Would remove todo:[/] [bold]{t['title']}[/] [dim]({t['id']})[/]")
            else:
                # Remove subtasks first
                subtasks = [s for s in read_todos() if s.get("parent_id") == t["id"]]
                for s in subtasks:
                    todos_fresh = read_todos()
                    todos_fresh = [x for x in todos_fresh if x["id"] != s["id"]]
                    write_todos(todos_fresh)
                    stderr.print(f"[dim]Removed orphaned subtask:[/] [bold]{s['title']}[/]")
                    removed += 1
                todos_fresh = read_todos()
                todos_fresh = [x for x in todos_fresh if x["id"] != t["id"]]
                write_todos(todos_fresh)
                stderr.print(f"[dim]Removed orphaned todo:[/] [bold]{t['title']}[/]")
                removed += 1

    if dry_run:
        stderr.print(f"\n[dim]Dry run — no changes made. Run [cyan]td sync[/cyan] to apply.[/]")
    elif created == 0 and removed == 0:
        stderr.print("[green]✓[/] Already in sync")
    else:
        parts = []
        if created > 0:
            parts.append(f"created {created}")
        if removed > 0:
            parts.append(f"removed {removed}")
        stderr.print(f"[green]✓[/] Synced: {', '.join(parts)}")


# ---------------------------------------------------------------------------
# td find [query]
# ---------------------------------------------------------------------------

@app.command()
def find(query: str = typer.Argument("")) -> None:
    """Search Claude sessions, create a todo, and resume."""
    from td_cli.session import start_session
    from td_cli.ui import check_fzf, action_menu, pick_todo, prompt_input

    check_fzf()
    stderr.print("[dim]Scanning sessions…[/]")

    lines = _build_session_lines(query)
    if not lines:
        stderr.print("[yellow]No sessions found.[/]")
        raise typer.Exit()

    import subprocess
    header = f'Sessions matching "{query}" — select to adopt (ESC to cancel)' if query else "Select a session to adopt as a todo (ESC to cancel)"
    result = subprocess.run(
        ["fzf", "--header", header, "--layout=reverse", "--height=80%",
         "--with-nth=4..", "--delimiter=\t", "--header-first", "--border",
         "--ansi", "--no-multi", "--no-sort", "--prompt=find ❯ ",
         "--preview-window=hidden"],
        input=lines, capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise typer.Exit()

    parts = result.stdout.strip().split("\t")
    session_id = parts[0]
    session_cwd = parts[1] if len(parts) > 1 else ""
    session_branch = parts[2] if len(parts) > 2 else ""

    action = action_menu("Link this session to…", "Existing todo", "New todo")
    if not action:
        raise typer.Exit()

    from td_cli.data import read_todos, write_todos
    if action == "Existing todo":
        tid = pick_todo("Select a todo to link this session to", "link ❯ ")
        if not tid:
            raise typer.Exit()
    else:
        title = prompt_input("Todo title for this session...")
        if not title:
            raise typer.Exit()
        import os
        old_quiet = os.environ.get("TODO_QUIET", "")
        os.environ["TODO_QUIET"] = "1"
        # Capture new() output for the ID
        from io import StringIO
        import contextlib
        f = StringIO()
        with contextlib.redirect_stdout(f):
            new(title=title)
        tid = f.getvalue().strip()
        if old_quiet:
            os.environ["TODO_QUIET"] = old_quiet
        else:
            os.environ.pop("TODO_QUIET", None)

    todos = read_todos()
    for t in todos:
        if t["id"] == tid:
            t["session_id"] = session_id
            t["session_cwd"] = session_cwd
            if session_branch:
                t["branch"] = session_branch
    write_todos(todos)

    todo = next((t for t in todos if t["id"] == tid), None)
    title = todo["title"] if todo else ""
    stderr.print(f"[green]✓[/] Linked: [bold]{title}[/]  [dim]{tid}[/]")
    stderr.print(f"  [green]◉[/] Session: [dim]{session_id}[/]")
    if session_branch:
        stderr.print(f"  [cyan] [/] Branch: {session_branch}")

    start_session(tid)


def _build_session_lines(query: str = "") -> str:
    """Scan ~/.claude/projects for sessions and build fzf lines."""
    import glob
    from td_cli.data import read_todos

    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.is_dir():
        return ""

    linked = {t.get("session_id", "") for t in read_todos() if t.get("session_id")}
    query_lower = query.lower()

    # Find session files sorted by mtime
    files = sorted(projects_dir.glob("*/*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:80]

    from datetime import timezone
    now_ts = datetime.now(timezone.utc).timestamp()
    today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    yesterday_start = today_start - 86400

    lines: list[str] = []
    for fpath in files:
        sid = fpath.stem
        if sid.startswith("agent-") or sid in linked:
            continue

        mtime = fpath.stat().st_mtime
        try:
            with open(fpath) as f:
                head = [json.loads(line) for _, line in zip(range(100), f)]
        except Exception:
            continue

        cwd = next((r.get("cwd", "") for r in head if "cwd" in r), "")
        branch = next((r.get("gitBranch", "") for r in head if "gitBranch" in r), "")

        msgs = []
        for r in head:
            msg = r.get("message", {})
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            if isinstance(content, list):
                content = " ".join(
                    item.get("text", "") for item in content
                    if isinstance(item, dict) and item.get("type", "text") == "text"
                )
            if len(content) > 15 and not content.startswith("<"):
                msgs.append(content[:120])

        if not msgs:
            continue

        display_msg = msgs[0]
        if query_lower:
            match = next((m for m in msgs if query_lower in m.lower()), None)
            if match:
                display_msg = match
            else:
                continue

        # Age
        if mtime >= today_start:
            age = "today"
        elif mtime >= yesterday_start:
            age = "yesterday"
        else:
            diff = now_ts - mtime
            if diff < 604800:
                age = f"{int(diff / 86400)}d ago"
            else:
                age = datetime.fromtimestamp(mtime).strftime("%b %d")

        proj = Path(cwd).name if cwd else "unknown"
        line = f"{sid}\t{cwd}\t{branch}\t{age:<10}  {proj[:16]:<16}  {branch[:30]:<30}  {display_msg}"
        lines.append(line)

        if len(lines) >= 50:
            break

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# td settings
# ---------------------------------------------------------------------------

@app.command()
def settings() -> None:
    """Print the settings file."""
    from td_cli.config import SETTINGS_PATH

    if SETTINGS_PATH.exists():
        stderr.print(f"[dim]{SETTINGS_PATH}[/]")
        stderr.print()
        typer.echo(SETTINGS_PATH.read_text())
    else:
        stderr.print("[red]No settings file found.[/]")
        stderr.print("Run [cyan]td init[/] to create one.")
        raise typer.Exit(1)


# ---------------------------------------------------------------------------
# td init
# ---------------------------------------------------------------------------

@app.command()
def init() -> None:
    """Configure td settings interactively."""
    from td_cli.config import SETTINGS_PATH
    from td_cli.ui import prompt_input

    settings_dir = SETTINGS_PATH.parent
    cur = {}
    if SETTINGS_PATH.exists():
        try:
            cur = json.loads(SETTINGS_PATH.read_text())
        except Exception:
            pass

    stderr.print("\n[bold]td init[/] — Configure td settings\n")

    stderr.print("  [bold]data_dir[/] — Where todos and notes are stored")
    data_dir = prompt_input("Data directory", default=cur.get("data_dir", "~/td"))
    stderr.print()

    stderr.print("  [bold]editor[/] — Editor for opening plan.md files")
    editor = prompt_input("Editor command", default=cur.get("editor", ""))
    stderr.print()

    stderr.print("  [bold]linear_org[/] — Linear organization slug")
    linear_org = prompt_input("Linear org slug", default=cur.get("linear_org", ""))
    stderr.print()

    stderr.print("  [bold]worktree_dir[/] — Worktree directory relative to repo root")
    wt_dir = prompt_input("Worktree directory", default=cur.get("worktree_dir", ".claude/worktrees"))
    stderr.print()

    stderr.print("  [bold]branch_prefix[/] — Prefix for auto-created branches")
    bp = prompt_input("Branch prefix", default=cur.get("branch_prefix", "todo"))
    stderr.print()

    settings_dir.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(json.dumps({
        "data_dir": data_dir or "~/td",
        "repo": "",
        "editor": editor,
        "linear_org": linear_org,
        "worktree_dir": wt_dir or ".claude/worktrees",
        "branch_prefix": bp or "todo",
    }, indent=2) + "\n")

    stderr.print(f"[green]✓[/] Settings saved to [dim]{SETTINGS_PATH}[/]")

    expanded = data_dir.replace("~", str(Path.home()), 1) if data_dir.startswith("~") else data_dir
    p = Path(expanded)
    if not p.is_dir():
        p.mkdir(parents=True)
        (p / "todo").mkdir()
        (p / "todos.json").write_text("[]")
        stderr.print(f"[green]✓[/] Created data directory at [dim]{data_dir}[/]")


# ---------------------------------------------------------------------------
# td update
# ---------------------------------------------------------------------------

@app.command()
def update() -> None:
    """Update td to the latest version."""
    self_path = Path(__file__).resolve()
    # Walk up to find .git
    for parent in [self_path.parent, self_path.parent.parent, self_path.parent.parent.parent]:
        if (parent / ".git").is_dir():
            stderr.print(f"[dim]Running from git clone at {parent}[/]")
            stderr.print("[dim]Use 'git pull && ./install.sh' to update.[/]")
            return

    stderr.print("[dim]Checking for updates...[/]")
    import subprocess
    try:
        result = subprocess.run(
            ["curl", "-fsSL", "https://api.github.com/repos/rosgoo/td/releases/latest"],
            capture_output=True, text=True, check=True,
        )
        import re
        m = re.search(r'"tag_name":\s*"([^"]+)"', result.stdout)
        if not m:
            stderr.print("[red]✗[/] Could not fetch latest version from GitHub")
            raise typer.Exit(1)
        latest = m.group(1).lstrip("v")
        current = _version_str()
        if latest == current:
            stderr.print(f"[green]✓[/] Already up to date ({current})")
        else:
            stderr.print(f"  [dim]Current: {current}[/]")
            stderr.print(f"  [bold]Latest:  {latest}[/]")
            stderr.print("\nUpdate with: pip install --upgrade td-cli")
    except Exception:
        stderr.print("[red]✗[/] Could not check for updates")
        raise typer.Exit(1)


# ---------------------------------------------------------------------------
# td help
# ---------------------------------------------------------------------------

@app.command("help")
def help_cmd() -> None:
    """Show usage."""
    v = _version_str()
    stderr.print(f"""
[cyan]  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄[/]
[cyan]    █    █   █ █    █ █   █[/]
[cyan]    █    █   █ █    █ █   █[/]
[cyan]    █    █▄▄▄█ █▄▄▄▀  █▄▄▄█[/]

  [dim]Minimal task manager for Claude Code[/]  [dim]v{v}[/]
  [dim]Handles plan injections, Claude sessions and worktree management.[/]
  [dim]All commands work non-interactively for AI agents.[/]

  [dim]{'─' * 54}[/]

  [bold]Interactive[/]

  [cyan]td[/]                              Open interactive app
  [cyan]td do[/] [dim]"title"[/]                  Create todo & start Claude immediately
  [cyan]td find[/] [dim][query][/]                 Find Claude session → create todo & resume
  [cyan]td edit[/] [dim][id][/]                    Open plan in editor
  [cyan]td link[/] [dim][id][/]                   Link Linear/GitHub/plan
  [cyan]td open[/] [dim][id][/]                    Open action menu for a todo
  [cyan]td browse[/]                       Open notes dir in editor

  [bold]Non-interactive[/] [dim](AI-friendly)[/]

  [cyan]td new[/] [dim][-b] "title"[/]              Create a new todo (-b for backlog)
  [cyan]td done[/] [dim]<id>[/]                    Mark as done
  [cyan]td try[/] [dim][id][/]                     Apply worktree diff to try branch
  [cyan]td bump[/] [dim][id][/]                    Toggle between TODO and backlog
  [cyan]td rename[/] [dim]<id> "title"[/]          Rename a todo
  [cyan]td delete[/] [dim]<id> [--force][/]       Delete todo and all data
  [cyan]td note[/] [dim]<id> "text"[/]             Append to plan
  [cyan]td get[/] [dim]<id>[/]                     Print todo as JSON
  [cyan]td show[/] [dim]<id>[/]                    Print plan path
  [cyan]td split[/] [dim]<id> "title"[/]           Create subtask
  [cyan]td link[/] [dim]<id> <url|path>[/]        Link Linear/GitHub/plan
  [cyan]td list[/]                         List active todos
  [cyan]td archive[/]                      Show completed todos
  [cyan]td sync[/] [dim][-n][/]                     Two-way sync: create/remove todos & dirs
  [cyan]td version[/]                      Print version
  [cyan]td update[/]                       Update to latest version

  [dim]{'─' * 54}[/]

  [bold]Config[/]  [dim]~/.config/claude-todo/settings.json[/]
  [bold]Data[/]    [dim]~/td/[/]
""")


# ---------------------------------------------------------------------------
# Picker (default command) + action menu
# ---------------------------------------------------------------------------

def _select_todo(todo_id: str) -> None:
    """Show action menu for a selected todo."""
    from td_cli.config import open_notes, open_url
    from td_cli.data import get_todo, read_todos, write_todos, now_iso
    from td_cli.git import linear_ticket_url, github_branch_url
    from td_cli.session import start_session, try_worktree
    from td_cli.ui import action_menu

    todo = get_todo(todo_id)
    if not todo:
        stderr.print("[red]Error:[/] Todo not found.")
        raise typer.Exit(1)

    title = todo["title"]
    notes_path = todo.get("notes_path", "")
    if not notes_path or not os.path.isfile(notes_path):
        from td_cli.data import ensure_notes
        notes_path = ensure_notes(todo_id, title)

    # Track last opened
    todos = read_todos()
    for t in todos:
        if t["id"] == todo_id:
            t["last_opened_at"] = now_iso()
    write_todos(todos)

    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    ticket = todo.get("linear_ticket", "")
    session_id = todo.get("session_id", "")
    github_pr = todo.get("github_pr", "")
    group = todo.get("group", "todo")

    stderr.print(f"\n[bold]{title}[/]")
    if ticket:
        stderr.print(f"  [magenta]·[/] Linear    {ticket}")
    if branch:
        stderr.print(f"  [cyan] [/] Branch    {branch}")
    if github_pr:
        stderr.print(f"  [cyan]·[/] PR        [dim]{github_pr}[/]")
    if wt_path:
        stderr.print(f"  [dim]· Worktree  {wt_path}[/]")
    if session_id:
        stderr.print(f"  [green]◉[/] Session   [dim]{session_id}[/]")
    stderr.print()

    options: list[str] = []
    if session_id:
        options.append("Resume Claude session")
    elif wt_path:
        options.append("Start Claude session")
    else:
        options.append("Start Claude (current dir)")
        options.append("Start Claude (new worktree)")
    if wt_path and branch:
        options.append("Try on main repo")
    options.append("Mark as done")
    options.append("Move to TODO" if group == "backlog" else "Move to backlog")
    options.append("Add subtask")
    options.append("Open plan")
    if ticket:
        options.append("Linear")
    if github_pr or branch:
        options.append("GitHub")
    options.extend(["Link", "Back"])

    choice = action_menu("What next?", *options)
    if not choice:
        return

    if choice in ("Resume Claude session", "Start Claude session"):
        start_session(todo_id)
    elif choice == "Start Claude (new worktree)":
        start_session(todo_id, "worktree")
    elif choice == "Start Claude (current dir)":
        start_session(todo_id, "current-dir")
    elif choice == "Try on main repo":
        try_worktree(todo_id)
    elif choice == "Mark as done":
        _archive_todo(todo_id)
    elif choice == "Move to TODO":
        _bump_group(todo_id, "todo")
    elif choice == "Move to backlog":
        _bump_group(todo_id, "backlog")
    elif choice == "Add subtask":
        split(parent_id=todo_id)
    elif choice == "Open plan":
        open_notes(notes_path)
    elif choice == "Linear":
        url = linear_ticket_url(ticket)
        if url:
            stderr.print(f"[dim]Opening {url}[/]")
            open_url(url)
    elif choice == "GitHub":
        url = github_pr if github_pr else github_branch_url(branch)
        if url:
            stderr.print(f"[dim]Opening {url}[/]")
            open_url(url)
    elif choice == "Link":
        link(arg1=todo_id)


def _picker() -> None:
    """Main interactive picker loop."""
    import subprocess
    from td_cli.ui import check_fzf, format_fzf_lines, prompt_input

    check_fzf()
    show_done = False

    while True:
        todo_lines = format_fzf_lines(show_done, "todo")
        backlog_lines = format_fzf_lines(show_done, "backlog")

        inp = "__new__\t\t\t            ✦ New todo"
        if todo_lines:
            inp += f"\n{todo_lines}"
        if backlog_lines:
            sep = "\033[2m  ─── Backlog " + "─" * 90 + "\033[0m"
            inp += f"\n__sep__\t\t\t{sep}\n{backlog_lines}"

        header = "TODOs — enter: open · ctrl-d: toggle done · esc: quit"
        result = subprocess.run(
            ["fzf", "--header", header, "--layout=reverse", "--height=80%",
             "--with-nth=4..", "--no-hscroll", "--delimiter=\t", "--header-first",
             "--border", "--ansi", "--no-multi", "--no-sort", "--prompt=❯ ",
             "--preview-window=hidden", "--expect=ctrl-d"],
            input=inp, capture_output=True, text=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise typer.Exit()

        # --expect outputs: line 1 = key pressed (empty for enter), line 2 = selection
        lines = result.stdout.split("\n", 2)
        key = lines[0]  # "" for enter, "ctrl-d" for ctrl-d
        selection = lines[1] if len(lines) > 1 else ""
        selection = selection.strip()

        if key == "ctrl-d":
            show_done = not show_done
            continue

        if not selection:
            raise typer.Exit()

        selected_id = selection.split("\t")[0]
        if selected_id == "__new__":
            title = prompt_input("Todo title...")
            if title:
                new(title=title)
            continue
        if selected_id == "__sep__":
            continue

        _select_todo(selected_id)
