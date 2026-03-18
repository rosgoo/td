"""Git repository, URL, and worktree path helpers."""

import subprocess

from td_cli.config import REPO_ROOT, WORKTREE_DIR, LINEAR_ORG, console


def require_repo() -> str:
    """Return REPO_ROOT or exit with error."""
    if not REPO_ROOT:
        console.print("[red]Error:[/] Not in a git repository. Run from a repo or set TODO_REPO.")
        raise SystemExit(1)
    return REPO_ROOT


def worktree_dir() -> str:
    return f"{require_repo()}/{WORKTREE_DIR}"


# --- URL construction -------------------------------------------------------

def github_repo_url() -> str:
    """Convert origin remote URL to HTTPS GitHub URL."""
    repo = require_repo()
    try:
        url = subprocess.run(
            ["git", "-C", repo, "remote", "get-url", "origin"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        return ""
    url = url.removesuffix(".git")
    url = url.replace("git@github.com:", "https://github.com/")
    return url


def github_branch_url(branch: str) -> str:
    """Return a GitHub URL for a branch."""
    if branch.startswith("http"):
        return branch
    repo_url = github_repo_url()
    if repo_url and branch:
        return f"{repo_url}/tree/{branch}"
    return ""


def linear_ticket_url(ticket: str) -> str:
    """Convert ticket ID to Linear app URL."""
    if ticket and LINEAR_ORG:
        return f"https://linear.app/{LINEAR_ORG}/issue/{ticket.lower()}"
    return ""


# --- Worktree validation ---------------------------------------------------

def validate_worktree(worktree_path: str) -> bool:
    """Check that a worktree path exists and is a valid git working tree."""
    import os
    if not os.path.isdir(worktree_path):
        return False
    return subprocess.run(
        ["git", "-C", worktree_path, "rev-parse", "--git-dir"],
        capture_output=True,
    ).returncode == 0


# --- URL parsing ------------------------------------------------------------

def extract_linear_ticket(url: str) -> str:
    """Extract ticket ID from Linear URL or raw ID."""
    if "linear.app" in url:
        # https://linear.app/maybern/issue/core-12207/some-title -> CORE-12207
        parts = url.split("/issue/")
        if len(parts) > 1:
            slug = parts[1].split("/")[0]
            return slug.upper()
    return url.upper()


def extract_github_branch(url: str) -> str:
    """Extract branch name from GitHub URL. PR URLs return empty."""
    if "github.com" in url and "/tree/" in url:
        return url.split("/tree/", 1)[1]
    if "github.com" in url and "/pull/" in url:
        return ""
    return url
