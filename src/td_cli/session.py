"""Git worktree lifecycle and Claude Code session management."""

import os
import subprocess
import uuid

from td_cli.config import REPO_ROOT, BRANCH_PREFIX, console
from td_cli.data import (
    get_todo, read_todos, write_todos, slugify,
)
from td_cli.git import require_repo, worktree_dir, validate_worktree
from td_cli.ui import prompt_confirm, prompt_choose


# --- Worktree creation ------------------------------------------------------

def init_worktree_for_todo(todo_id: str) -> str:
    """Create or reuse a git worktree for a todo. Returns worktree path."""
    repo = require_repo()
    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    title = todo["title"]
    branch = todo.get("branch") or ""
    slug = slugify(title)
    wt_path = f"{worktree_dir()}/{slug}"

    if not branch:
        branch = f"{BRANCH_PREFIX}/{slug}"

    # Check where branch exists
    has_local = subprocess.run(
        ["git", "-C", repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        capture_output=True,
    ).returncode == 0

    has_remote = False
    try:
        result = subprocess.run(
            ["git", "-C", repo, "ls-remote", "--heads", "origin", branch],
            capture_output=True, text=True,
        )
        has_remote = bool(result.stdout.strip())
    except Exception:
        pass

    if has_local:
        console.print(f"[yellow]Branch '{branch}' already exists locally. Using it.[/]")
        if has_remote:
            console.print("[dim]Fetching latest from remote...[/]")
            subprocess.run(["git", "-C", repo, "fetch", "origin", branch],
                           capture_output=True)
        # Check for existing worktree
        existing_wt = _find_worktree_for_branch(repo, branch)
        if existing_wt:
            console.print(f"[dim]Found existing worktree at {existing_wt}[/]")
            wt_path = existing_wt
        else:
            os.makedirs(os.path.dirname(wt_path), exist_ok=True)
            subprocess.run(
                ["git", "-C", repo, "worktree", "add", wt_path, branch],
                capture_output=True,
            )
        if has_remote:
            subprocess.run(
                ["git", "-C", wt_path, "merge", "--ff-only", f"origin/{branch}"],
                capture_output=True,
            )
    elif has_remote:
        console.print(f"[dim]Branch '{branch}' found on remote. Fetching...[/]")
        subprocess.run(["git", "-C", repo, "fetch", "origin", branch], capture_output=True)
        os.makedirs(os.path.dirname(wt_path), exist_ok=True)
        subprocess.run(
            ["git", "-C", repo, "worktree", "add", "--track", "-b", branch, wt_path, f"origin/{branch}"],
            capture_output=True,
        )
    else:
        base = "master"
        if subprocess.run(
            ["git", "-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/master"],
            capture_output=True,
        ).returncode != 0:
            base = "main"
        os.makedirs(os.path.dirname(wt_path), exist_ok=True)
        console.print(f"[dim]Creating worktree on branch {branch} from {base}...[/]")
        subprocess.run(
            ["git", "-C", repo, "worktree", "add", "-b", branch, wt_path, base],
            capture_output=True,
        )

    # Update todo record
    todos = read_todos()
    for t in todos:
        if t["id"] == todo_id:
            t["branch"] = branch
            t["worktree_path"] = wt_path
    write_todos(todos)
    return wt_path


def _find_worktree_for_branch(repo: str, branch: str) -> str | None:
    """Find an existing worktree path for a branch."""
    result = subprocess.run(
        ["git", "-C", repo, "worktree", "list", "--porcelain"],
        capture_output=True, text=True,
    )
    wt = None
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            wt = line[9:]
        if line.startswith("branch refs/heads/") and line[18:] == branch:
            return wt
    return None


# --- Try (apply worktree diff to main repo) ---------------------------------

def try_worktree(todo_id: str) -> None:
    """Apply worktree diff to a try branch on the main repo."""
    repo = require_repo()
    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    title = todo["title"]

    if not wt_path:
        console.print("[red]Error:[/] This todo has no worktree. 'try' only works with worktree sessions.")
        raise SystemExit(1)

    if not validate_worktree(wt_path):
        console.print(f"[red]Error:[/] Worktree at {wt_path} is missing or invalid.")
        raise SystemExit(1)

    # Determine base branch
    base = "master"
    if subprocess.run(
        ["git", "-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/master"],
        capture_output=True,
    ).returncode != 0:
        base = "main"

    # Check for changes
    diff = subprocess.run(
        ["git", "-C", wt_path, "diff", f"{base}...HEAD"],
        capture_output=True, text=True,
    ).stdout
    if not diff:
        console.print(f"[yellow]No changes[/] between {base} and {branch}.")
        return

    slug = slugify(title)
    try_branch = f"try-{slug}"

    # Check for uncommitted changes
    dirty = (
        subprocess.run(["git", "-C", repo, "diff", "--quiet"], capture_output=True).returncode != 0
        or subprocess.run(["git", "-C", repo, "diff", "--cached", "--quiet"], capture_output=True).returncode != 0
    )
    if dirty:
        console.print("[red]Error:[/] Main repo has uncommitted changes. Commit or stash them first.")
        raise SystemExit(1)

    console.print(f"[bold]Try:[/] {title}")
    console.print(f"[dim]Applying diff from {branch} onto {base} as {try_branch}[/]")

    # Delete existing try branch
    if subprocess.run(
        ["git", "-C", repo, "show-ref", "--verify", "--quiet", f"refs/heads/{try_branch}"],
        capture_output=True,
    ).returncode == 0:
        if not prompt_confirm(f"Branch '{try_branch}' already exists. Replace it?"):
            return
        current = subprocess.run(
            ["git", "-C", repo, "branch", "--show-current"],
            capture_output=True, text=True,
        ).stdout.strip()
        if current == try_branch:
            subprocess.run(["git", "-C", repo, "checkout", base], capture_output=True)
        subprocess.run(["git", "-C", repo, "branch", "-D", try_branch], capture_output=True)

    # Create try branch
    subprocess.run(["git", "-C", repo, "checkout", "-b", try_branch, base], capture_output=True)

    # Apply diff
    apply_result = subprocess.run(
        ["git", "-C", repo, "apply", "--index"],
        input=diff, capture_output=True, text=True,
    )
    if apply_result.returncode != 0:
        console.print("[red]Error:[/] Failed to apply diff cleanly. Resetting.")
        subprocess.run(["git", "-C", repo, "checkout", base], capture_output=True)
        subprocess.run(["git", "-C", repo, "branch", "-D", try_branch], capture_output=True)
        raise SystemExit(1)

    subprocess.run(["git", "-C", repo, "commit", "-m", f"try: {title}"], capture_output=True)
    console.print(f"[green]✓[/] Created [bold]{try_branch}[/] with changes from {branch}")
    console.print(f"[dim]Main repo is now on {try_branch}. Worktree is unchanged.[/]")


# --- Claude session launching -----------------------------------------------

def launch_claude(todo_id: str, session_id: str = "") -> None:
    """Launch claude with plan context. Replaces current process."""
    from td_cli.config import DATA_DIR

    # Unset CLAUDECODE to avoid nested-session issues
    os.environ.pop("CLAUDECODE", None)

    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    title = todo["title"]
    notes_path = todo.get("notes_path", "")
    ticket = todo.get("linear_ticket", "")
    branch = todo.get("branch", "")
    parent_id = todo.get("parent_id", "")
    github_pr = todo.get("github_pr", "")
    wt_path = todo.get("worktree_path", "")

    context = f"# Current Todo: {title}"
    context += f"\nTodo ID: {todo_id}"
    context += f"\nTD Directory: {DATA_DIR}"
    if ticket:
        context += f"\nLinear: {ticket}"
    if branch:
        context += f"\nBranch: {branch}"
    if github_pr:
        context += f"\nGitHub PR: {github_pr}"
    if wt_path:
        context += f"\nWorktree: {wt_path}"
    if notes_path:
        context += f"\nPlan: {notes_path}"

    # Parent context
    if parent_id:
        from td_cli.data import get_todo as _get
        parent = _get(parent_id)
        if parent:
            context += f"\nParent: {parent['title']}"
            pnotes = parent.get("notes_path", "")
            if pnotes and os.path.isfile(pnotes):
                context += f"\n\n## Parent plan\n\n{open(pnotes).read()}"

    # Own plan
    if notes_path and os.path.isfile(notes_path):
        context += f"\n\n## Plan\n\n{open(notes_path).read()}"

    if notes_path:
        context += f"\n\nWhen in plan mode, always write your plan to {notes_path} before exiting plan mode."

    args = ["claude"]
    if session_id:
        # Check session file exists
        encoded_cwd = os.getcwd().replace("/", "-")
        project_dir = os.path.expanduser(f"~/.claude/projects/{encoded_cwd}")
        session_file = f"{project_dir}/{session_id}.jsonl"
        if os.path.isfile(session_file):
            console.print(f"[green]◉[/] Resuming session [dim]{session_id}[/]")
            args += ["--resume", session_id]
        else:
            console.print("[yellow]◉[/] Previous session not found on disk. Starting fresh session.")
            session_id = str(uuid.uuid4())
            cwd = os.getcwd()
            todos = read_todos()
            for t in todos:
                if t["id"] == todo_id:
                    t["session_id"] = session_id
                    t["session_cwd"] = cwd
            write_todos(todos)
            args += ["--session-id", session_id]
    else:
        session_id = str(uuid.uuid4())
        cwd = os.getcwd()
        todos = read_todos()
        for t in todos:
            if t["id"] == todo_id:
                t["session_id"] = session_id
                t["session_cwd"] = cwd
        write_todos(todos)
        console.print(f"[blue]◉[/] Starting session [dim]{session_id}[/]")
        args += ["--session-id", session_id]

    args += ["--append-system-prompt", context]
    os.execvp("claude", args)


def start_session(todo_id: str, mode: str = "") -> None:
    """Entry point for starting/resuming a Claude session."""
    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    session_id = todo.get("session_id", "")

    # Case 1: Session exists but no worktree
    if session_id and not wt_path:
        session_cwd = todo.get("session_cwd", "")
        if not session_cwd or not os.path.isdir(session_cwd):
            # Try to discover from Claude session file
            import glob
            pattern = os.path.expanduser(f"~/.claude/projects/*/{session_id}.jsonl")
            files = glob.glob(pattern)
            if files:
                import json
                with open(files[0]) as f:
                    for line in f:
                        try:
                            obj = json.loads(line)
                            if "cwd" in obj:
                                session_cwd = obj["cwd"]
                                break
                        except json.JSONDecodeError:
                            continue

            if not session_cwd or not os.path.isdir(session_cwd):
                console.print(f"[red]Error:[/] Session [dim]{session_id}[/] has no saved directory.")
                raise SystemExit(1)

            # Backfill
            todos = read_todos()
            for t in todos:
                if t["id"] == todo_id:
                    t["session_cwd"] = session_cwd
            write_todos(todos)

        real_cwd = os.path.realpath(os.getcwd())
        real_scwd = os.path.realpath(session_cwd)
        if real_cwd != real_scwd:
            choice = prompt_choose(
                f"Session was started in {session_cwd}",
                "Switch to original directory",
                "Move session here",
                "Start a new session here",
                "Cancel",
            )
            if choice and choice.startswith("Switch"):
                os.chdir(session_cwd)
            elif choice and choice.startswith("Move"):
                old_encoded = session_cwd.replace("/", "-")
                new_encoded = os.getcwd().replace("/", "-")
                old_dir = os.path.expanduser(f"~/.claude/projects/{old_encoded}")
                new_dir = os.path.expanduser(f"~/.claude/projects/{new_encoded}")
                old_file = f"{old_dir}/{session_id}.jsonl"
                if os.path.isfile(old_file):
                    os.makedirs(new_dir, exist_ok=True)
                    os.rename(old_file, f"{new_dir}/{session_id}.jsonl")
                    console.print("[green]✓[/] Moved session to current directory.")
                todos = read_todos()
                for t in todos:
                    if t["id"] == todo_id:
                        t["session_cwd"] = os.getcwd()
                write_todos(todos)
            elif choice and choice.startswith("Start"):
                launch_claude(todo_id, "")
                return
            else:
                return

        launch_claude(todo_id, session_id)
        return

    # Case 2: No worktree yet
    if not wt_path:
        if mode == "worktree":
            require_repo()
            wt_path = init_worktree_for_todo(todo_id)
            todo = get_todo(todo_id)
            branch = todo.get("branch", "") if todo else ""
        elif mode == "current-dir":
            launch_claude(todo_id, session_id)
            return
        else:
            choice = prompt_choose(
                "No worktree — how to start?",
                "Create a worktree (new branch)",
                "Start Claude in current directory",
                "Cancel",
            )
            if choice and choice.startswith("Create"):
                require_repo()
                wt_path = init_worktree_for_todo(todo_id)
                todo = get_todo(todo_id)
                branch = todo.get("branch", "") if todo else ""
            elif choice and choice.startswith("Start"):
                launch_claude(todo_id, session_id)
                return
            else:
                return

    # Case 3: Worktree exists
    if not validate_worktree(wt_path):
        console.print(f"[yellow]Warning:[/] Worktree at {wt_path} is missing.")
        if prompt_confirm("Recreate worktree?"):
            require_repo()
            repo = REPO_ROOT
            os.makedirs(os.path.dirname(wt_path), exist_ok=True)
            if branch and subprocess.run(
                ["git", "-C", repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
                capture_output=True,
            ).returncode == 0:
                subprocess.run(["git", "-C", repo, "worktree", "add", wt_path, branch], capture_output=True)
            else:
                console.print(f"[red]Error:[/] Branch '{branch}' no longer exists.")
                raise SystemExit(1)
        else:
            return

    # Switch to worktree
    real_wt = os.path.realpath(wt_path)
    real_cwd = os.path.realpath(os.getcwd())
    if real_wt != real_cwd:
        if prompt_confirm(f"Session is in {wt_path}. Switch directory?"):
            os.chdir(wt_path)

    # Validate branch
    wt_branch = subprocess.run(
        ["git", "-C", wt_path, "branch", "--show-current"],
        capture_output=True, text=True,
    ).stdout.strip()
    if branch and wt_branch and wt_branch != branch:
        console.print(f"[yellow]Warning:[/] Worktree is on branch '{wt_branch}', todo expects '{branch}'.")
        if prompt_confirm(f"Switch to {branch}?"):
            subprocess.run(["git", "-C", wt_path, "checkout", branch], capture_output=True)

    launch_claude(todo_id, session_id)
