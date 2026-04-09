"""Git worktree lifecycle and Claude Code session management."""

import glob as _glob
import os
import shlex
import subprocess
import uuid

from td_cli.config import (
    BRANCH_PREFIX,
    CLAUDE_COMMAND,
    REPO_ROOT,
    WORKTREE_SCRIPT,
    console,
)
from td_cli.data import (
    get_todo,
    read_todos,
    slugify,
    write_todos,
)
from td_cli.git import require_repo, validate_worktree, worktree_dir
from td_cli.ui import confirm


def _find_session_file(session_id: str, hint_cwd: str = "") -> str | None:
    """Locate a Claude session file on disk.

    Claude Code encodes the CWD by replacing both '/' and '.' with '-'.
    Rather than replicating that exactly, we try the hint first and fall
    back to a glob across all project directories.
    """
    projects_base = os.path.expanduser("~/.claude/projects")
    if hint_cwd:
        encoded = hint_cwd.replace("/", "-").replace(".", "-")
        candidate = f"{projects_base}/{encoded}/{session_id}.jsonl"
        if os.path.isfile(candidate):
            return candidate
    # Fallback: glob across all project dirs
    matches = _glob.glob(f"{projects_base}/*/{session_id}.jsonl")
    return matches[0] if matches else None


def discover_sessions(cwd: str) -> list[dict]:
    """Find all Claude sessions for a directory, sorted by most recent first.

    Returns a list of dicts with keys: session_id, path, mtime.
    """
    projects_base = os.path.expanduser("~/.claude/projects")
    encoded = cwd.replace("/", "-").replace(".", "-")
    project_dir = f"{projects_base}/{encoded}"

    sessions = []
    if os.path.isdir(project_dir):
        for f in os.listdir(project_dir):
            if f.endswith(".jsonl"):
                path = os.path.join(project_dir, f)
                sessions.append({
                    "session_id": f[:-6],
                    "path": path,
                    "mtime": os.path.getmtime(path),
                })

    sessions.sort(key=lambda s: s["mtime"], reverse=True)
    return sessions


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
    has_local = (
        subprocess.run(
            [
                "git",
                "-C",
                repo,
                "show-ref",
                "--verify",
                "--quiet",
                f"refs/heads/{branch}",
            ],
            capture_output=True,
        ).returncode
        == 0
    )

    has_remote = False
    try:
        result = subprocess.run(
            ["git", "-C", repo, "ls-remote", "--heads", "origin", branch],
            capture_output=True,
            text=True,
        )
        has_remote = bool(result.stdout.strip())
    except Exception:
        pass

    if has_local:
        console.print(f"[yellow]Branch '{branch}' already exists locally. Using it.[/]")
        if has_remote:
            console.print("[dim]Fetching latest from remote...[/]")
            subprocess.run(
                ["git", "-C", repo, "fetch", "origin", branch], capture_output=True
            )
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
        subprocess.run(
            ["git", "-C", repo, "fetch", "origin", branch], capture_output=True
        )
        os.makedirs(os.path.dirname(wt_path), exist_ok=True)
        subprocess.run(
            [
                "git",
                "-C",
                repo,
                "worktree",
                "add",
                "--track",
                "-b",
                branch,
                wt_path,
                f"origin/{branch}",
            ],
            capture_output=True,
        )
    else:
        base = "master"
        if (
            subprocess.run(
                [
                    "git",
                    "-C",
                    repo,
                    "show-ref",
                    "--verify",
                    "--quiet",
                    "refs/heads/master",
                ],
                capture_output=True,
            ).returncode
            != 0
        ):
            base = "main"
        os.makedirs(os.path.dirname(wt_path), exist_ok=True)
        console.print(f"[dim]Creating worktree on branch {branch} from {base}...[/]")
        subprocess.run(
            ["git", "-C", repo, "worktree", "add", "-b", branch, wt_path, base],
            capture_output=True,
        )

    # Run worktree setup script in background if configured
    if WORKTREE_SCRIPT:
        console.print(f"[dim]Running worktree script in background: {WORKTREE_SCRIPT}[/]")
        subprocess.Popen(
            WORKTREE_SCRIPT,
            shell=True,
            cwd=wt_path,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
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
        capture_output=True,
        text=True,
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
        console.print(
            "[red]Error:[/] This todo has no worktree. 'try' only works with worktree sessions."
        )
        raise SystemExit(1)

    if not validate_worktree(wt_path):
        console.print(f"[red]Error:[/] Worktree at {wt_path} is missing or invalid.")
        raise SystemExit(1)

    # Determine base branch
    base = "master"
    if (
        subprocess.run(
            ["git", "-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/master"],
            capture_output=True,
        ).returncode
        != 0
    ):
        base = "main"

    # Check for changes
    diff = subprocess.run(
        ["git", "-C", wt_path, "diff", f"{base}...HEAD"],
        capture_output=True,
        text=True,
    ).stdout
    if not diff:
        console.print(f"[yellow]No changes[/] between {base} and {branch}.")
        return

    slug = slugify(title)
    try_branch = f"try-{slug}"

    # Check for uncommitted changes
    dirty = (
        subprocess.run(
            ["git", "-C", repo, "diff", "--quiet"], capture_output=True
        ).returncode
        != 0
        or subprocess.run(
            ["git", "-C", repo, "diff", "--cached", "--quiet"], capture_output=True
        ).returncode
        != 0
    )
    if dirty:
        console.print(
            "[red]Error:[/] Main repo has uncommitted changes. Commit or stash them first."
        )
        raise SystemExit(1)

    console.print(f"[bold]Try:[/] {title}")
    console.print(f"[dim]Applying diff from {branch} onto {base} as {try_branch}[/]")

    # Delete existing try branch
    if (
        subprocess.run(
            [
                "git",
                "-C",
                repo,
                "show-ref",
                "--verify",
                "--quiet",
                f"refs/heads/{try_branch}",
            ],
            capture_output=True,
        ).returncode
        == 0
    ):
        if not confirm(
            f"Branch '{try_branch}' already exists. Replace it?", default=False
        ):
            return
        current = subprocess.run(
            ["git", "-C", repo, "branch", "--show-current"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        if current == try_branch:
            subprocess.run(["git", "-C", repo, "checkout", base], capture_output=True)
        subprocess.run(
            ["git", "-C", repo, "branch", "-D", try_branch], capture_output=True
        )

    # Create try branch
    subprocess.run(
        ["git", "-C", repo, "checkout", "-b", try_branch, base], capture_output=True
    )

    # Apply diff
    apply_result = subprocess.run(
        ["git", "-C", repo, "apply", "--index"],
        input=diff,
        capture_output=True,
        text=True,
    )
    if apply_result.returncode != 0:
        console.print("[red]Error:[/] Failed to apply diff cleanly. Resetting.")
        subprocess.run(["git", "-C", repo, "checkout", base], capture_output=True)
        subprocess.run(
            ["git", "-C", repo, "branch", "-D", try_branch], capture_output=True
        )
        raise SystemExit(1)

    subprocess.run(
        ["git", "-C", repo, "commit", "-m", f"try: {title}"], capture_output=True
    )
    console.print(
        f"[green]✓[/] Created [bold]{try_branch}[/] with changes from {branch}"
    )
    console.print(f"[dim]Main repo is now on {try_branch}. Worktree is unchanged.[/]")


# --- Take (bring try branch changes back to worktree) -----------------------


def take_worktree(todo_id: str) -> None:
    """Cherry-pick commits made on the try branch back into the worktree."""
    repo = require_repo()
    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    title = todo["title"]

    if not wt_path:
        console.print(
            "[red]Error:[/] This todo has no worktree. 'take' only works with worktree sessions."
        )
        raise SystemExit(1)

    if not validate_worktree(wt_path):
        console.print(f"[red]Error:[/] Worktree at {wt_path} is missing or invalid.")
        raise SystemExit(1)

    slug = slugify(title)
    try_branch = f"try-{slug}"

    # Verify try branch exists
    if (
        subprocess.run(
            [
                "git",
                "-C",
                repo,
                "show-ref",
                "--verify",
                "--quiet",
                f"refs/heads/{try_branch}",
            ],
            capture_output=True,
        ).returncode
        != 0
    ):
        console.print(
            f"[red]Error:[/] No try branch '{try_branch}' found. Run 'td try' first."
        )
        raise SystemExit(1)

    # Find the initial "try:" commit (first commit on the try branch after base)
    try_commits = (
        subprocess.run(
            ["git", "-C", repo, "log", try_branch, "--format=%H %s", "--reverse"],
            capture_output=True,
            text=True,
        )
        .stdout.strip()
        .splitlines()
    )

    if not try_commits:
        console.print(f"[yellow]No commits[/] on {try_branch}.")
        return

    # The first commit with "try: " prefix is the initial td try commit
    initial_hash = None
    for line in try_commits:
        parts = line.split(" ", 1)
        if len(parts) == 2 and parts[1].startswith("try: "):
            initial_hash = parts[0]
            break

    if not initial_hash:
        console.print(
            f"[red]Error:[/] Could not find the initial 'try:' commit on {try_branch}."
        )
        raise SystemExit(1)

    # Get commits after the initial try commit
    new_commits_output = subprocess.run(
        [
            "git",
            "-C",
            repo,
            "log",
            f"{initial_hash}..{try_branch}",
            "--format=%H",
            "--reverse",
        ],
        capture_output=True,
        text=True,
    ).stdout.strip()

    if not new_commits_output:
        console.print(
            f"[yellow]No new commits[/] on {try_branch} beyond the initial try."
        )
        return

    new_commits = new_commits_output.splitlines()
    console.print(f"[bold]Take:[/] {title}")
    console.print(
        f"[dim]Cherry-picking {len(new_commits)} commit(s) from {try_branch} into {branch}[/]"
    )

    # Check for uncommitted changes in worktree
    dirty = (
        subprocess.run(
            ["git", "-C", wt_path, "diff", "--quiet"], capture_output=True
        ).returncode
        != 0
        or subprocess.run(
            ["git", "-C", wt_path, "diff", "--cached", "--quiet"], capture_output=True
        ).returncode
        != 0
    )
    if dirty:
        console.print(
            "[red]Error:[/] Worktree has uncommitted changes. Commit or stash them first."
        )
        raise SystemExit(1)

    # Cherry-pick each commit
    failed = False
    picked = 0
    for commit_hash in new_commits:
        result = subprocess.run(
            ["git", "-C", wt_path, "cherry-pick", commit_hash],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            console.print(f"[red]Error:[/] Cherry-pick failed for {commit_hash[:8]}.")
            console.print(f"[dim]{result.stderr.strip()}[/]")
            console.print(
                f"[dim]Resolve conflicts in {wt_path}, then run 'git cherry-pick --continue'.[/]"
            )
            failed = True
            break
        picked += 1

    if not failed:
        console.print(f"[green]✓[/] Cherry-picked {picked} commit(s) into {branch}")
        if confirm(f"Delete try branch '{try_branch}'?", default=True):
            # Switch main repo off try branch if needed
            current = subprocess.run(
                ["git", "-C", repo, "branch", "--show-current"],
                capture_output=True,
                text=True,
            ).stdout.strip()
            if current == try_branch:
                base = "master"
                if (
                    subprocess.run(
                        [
                            "git",
                            "-C",
                            repo,
                            "show-ref",
                            "--verify",
                            "--quiet",
                            "refs/heads/master",
                        ],
                        capture_output=True,
                    ).returncode
                    != 0
                ):
                    base = "main"
                subprocess.run(
                    ["git", "-C", repo, "checkout", base], capture_output=True
                )
            subprocess.run(
                ["git", "-C", repo, "branch", "-D", try_branch], capture_output=True
            )
            console.print(f"[dim]Deleted {try_branch}[/]")


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

    cmd_parts = shlex.split(CLAUDE_COMMAND)
    executable = cmd_parts[0]
    args = list(cmd_parts)
    if session_id:
        # Check session file exists — use stored session_cwd as a hint for
        # the project directory encoding, with glob fallback for worktree
        # paths where Claude Code's encoding differs from a simple replace.
        session_cwd = todo.get("session_cwd", "") if todo else ""
        hint = session_cwd if session_cwd else os.getcwd()
        session_file = _find_session_file(session_id, hint)
        if session_file:
            # Switch to the directory where the session lives so Claude can
            # find and resume it.
            if session_cwd and os.path.isdir(session_cwd):
                os.chdir(session_cwd)
            console.print(f"[green]◉[/] Resuming session [dim]{session_id}[/]")
            args += ["--resume", session_id]
        else:
            console.print(
                "[yellow]◉[/] Previous session not found on disk. Starting fresh session."
            )
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
    os.execvp(executable, args)


def start_session(todo_id: str, here: bool = False) -> None:
    """Entry point for starting/resuming a Claude session.

    By default, creates a worktree for top-level tasks. Subtasks use their
    parent's worktree. Pass here=True to skip worktree creation and use the
    current directory.
    """
    todo = get_todo(todo_id)
    if not todo:
        raise SystemExit(1)

    wt_path = todo.get("worktree_path", "")
    branch = todo.get("branch", "")
    is_subtask = bool(todo.get("parent_id", ""))

    # No worktree yet — create one (unless subtask, or --here)
    if not wt_path and not here and not is_subtask:
        require_repo()
        wt_path = init_worktree_for_todo(todo_id)
        todo = get_todo(todo_id)
        branch = todo.get("branch", "") if todo else ""

    # If we have a worktree, validate and switch into it
    if wt_path:
        if not validate_worktree(wt_path):
            console.print(f"[yellow]Warning:[/] Worktree at {wt_path} is missing.")
            if confirm("Recreate worktree?", default=False):
                require_repo()
                repo = REPO_ROOT
                os.makedirs(os.path.dirname(wt_path), exist_ok=True)
                if (
                    branch
                    and subprocess.run(
                        [
                            "git",
                            "-C",
                            repo,
                            "show-ref",
                            "--verify",
                            "--quiet",
                            f"refs/heads/{branch}",
                        ],
                        capture_output=True,
                    ).returncode
                    == 0
                ):
                    subprocess.run(
                        ["git", "-C", repo, "worktree", "add", wt_path, branch],
                        capture_output=True,
                    )
                else:
                    console.print(
                        f"[red]Error:[/] Branch '{branch}' no longer exists."
                    )
                    raise SystemExit(1)
            else:
                return

        # Switch to worktree
        real_wt = os.path.realpath(wt_path)
        real_cwd = os.path.realpath(os.getcwd())
        if real_wt != real_cwd:
            os.chdir(wt_path)

        # Validate branch
        wt_branch = subprocess.run(
            ["git", "-C", wt_path, "branch", "--show-current"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        if branch and wt_branch and wt_branch != branch:
            console.print(
                f"[yellow]Warning:[/] Worktree on '{wt_branch}', expected '{branch}'."
            )
            if confirm(f"Switch to {branch}?", default=True):
                subprocess.run(
                    ["git", "-C", wt_path, "checkout", branch], capture_output=True
                )

        # Discover most recent session in this worktree
        sessions = discover_sessions(wt_path)
        session_id = sessions[0]["session_id"] if sessions else ""
        launch_claude(todo_id, session_id)
    else:
        # --here or subtask without parent worktree: use current directory
        launch_claude(todo_id, todo.get("session_id", ""))
