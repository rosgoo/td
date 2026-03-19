"""Settings, paths, and output helpers."""

import json
import os
import subprocess
import sys
from pathlib import Path

from rich.console import Console

console = Console(stderr=True)

# --- Settings ---------------------------------------------------------------

SETTINGS_PATH = Path(os.environ.get(
    "TODO_SETTINGS",
    Path.home() / ".config" / "claude-todo" / "settings.json",
))


def _load_settings() -> dict:
    if SETTINGS_PATH.exists():
        try:
            return json.loads(SETTINGS_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


_settings = _load_settings()


def _s(key: str) -> str:
    """Get a setting value, expanding ~ to home."""
    val = _settings.get(key, "")
    if isinstance(val, str) and val.startswith("~"):
        val = str(Path.home()) + val[1:]
    return val


# --- Paths ------------------------------------------------------------------

DATA_DIR = Path(os.environ.get("TODO_DATA_DIR", "") or _s("data_dir") or Path.home() / "td")
TODOS_FILE = DATA_DIR / "todos.json"
NOTES_DIR = DATA_DIR / "todo"
DONE_DIR = DATA_DIR / "done"

_repo_env = os.environ.get("TODO_REPO", "")
if _repo_env:
    REPO_ROOT: str | None = _repo_env
else:
    _repo_setting = _s("repo")
    if _repo_setting:
        REPO_ROOT = _repo_setting
    else:
        try:
            REPO_ROOT = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=True,
            ).stdout.strip() or None
        except (subprocess.CalledProcessError, FileNotFoundError):
            REPO_ROOT = None

_editor_env = os.environ.get("TODO_EDITOR", "")
if _editor_env:
    NOTES_EDITOR = _editor_env
elif _s("editor"):
    NOTES_EDITOR = _s("editor")
elif os.name == "posix" and subprocess.run(
    ["which", "open"], capture_output=True
).returncode == 0:
    NOTES_EDITOR = "open"
else:
    NOTES_EDITOR = "vi"

LINEAR_ORG = os.environ.get("TODO_LINEAR_ORG", "") or _s("linear_org")
WORKTREE_DIR = os.environ.get("TODO_WORKTREE_DIR", "") or _s("worktree_dir") or ".claude/worktrees"
BRANCH_PREFIX = os.environ.get("TODO_BRANCH_PREFIX", "") or _s("branch_prefix") or "todo"

QUIET = bool(os.environ.get("TODO_QUIET", ""))


# --- Output helpers ---------------------------------------------------------

def info(*args: str) -> None:
    """Print info message to stderr (suppressed in quiet mode)."""
    if not QUIET:
        console.print(*args)


# --- Editor helpers ---------------------------------------------------------

def open_notes(target: str) -> None:
    """Open a notes file or directory in the configured editor."""
    if NOTES_EDITOR == "obsidian":
        vault_name = DATA_DIR.name
        rel_path = str(Path(target).relative_to(DATA_DIR))
        if rel_path.endswith(".md"):
            rel_path = rel_path[:-3]
        import urllib.parse
        encoded = urllib.parse.quote(rel_path)
        subprocess.run([
            "osascript", "-e",
            f'open location "obsidian://open?vault={vault_name}&file={encoded}"',
        ])
    else:
        subprocess.run([NOTES_EDITOR, target])


def open_url(url: str) -> None:
    """Open a URL in the system browser."""
    if subprocess.run(["which", "open"], capture_output=True).returncode == 0:
        subprocess.run(["open", url])
    elif subprocess.run(["which", "xdg-open"], capture_output=True).returncode == 0:
        subprocess.run(["xdg-open", url])
    else:
        console.print(f"[red]Cannot open URL:[/] {url}")
        console.print("Install xdg-open or open the URL manually.")
        raise SystemExit(1)
