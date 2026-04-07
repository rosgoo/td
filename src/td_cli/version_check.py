"""Non-blocking update check using a local cache file.

On every launch we read a tiny JSON cache (~/.config/claude-todo/update-check.json).
If it says a newer version is available, we print a one-liner to stderr.
If the cache is stale (>24 h), we spawn a detached background process to refresh it.
The current invocation never blocks on the network.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

_CACHE_DIR = Path(os.environ.get(
    "TODO_SETTINGS",
    Path.home() / ".config" / "claude-todo" / "settings.json",
)).parent
_CACHE_FILE = _CACHE_DIR / "update-check.json"
_CHECK_INTERVAL = 172800  # 48 hours
_GITHUB_API = "https://api.github.com/repos/rosgoo/td/releases/latest"


def _read_cache() -> dict | None:
    try:
        return json.loads(_CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _current_version() -> str:
    from importlib.metadata import PackageNotFoundError, version

    try:
        return version("td")
    except PackageNotFoundError:
        return "dev"


def _parse_version(v: str) -> tuple[int, ...]:
    """Parse '0.6.4' into (0, 6, 4) for comparison."""
    try:
        return tuple(int(x) for x in v.split("."))
    except (ValueError, AttributeError):
        return (0,)


def check_for_update() -> None:
    """Print an update notice if available, and refresh the cache in the background."""
    if os.environ.get("TODO_NO_UPDATE_CHECK"):
        return

    current = _current_version()
    if current == "dev":
        return

    cache = _read_cache()

    # Show notice from cached data
    if cache and cache.get("latest"):
        latest = cache["latest"]
        if _parse_version(latest) > _parse_version(current):
            from rich.console import Console
            Console(stderr=True).print(
                f"[dim]Update available: {current} → [bold]{latest}[/bold]  "
                f"(run [bold]td update[/bold])[/]"
            )

    # Refresh cache in background if stale
    checked_at = (cache or {}).get("checked_at", 0)
    if time.time() - checked_at > _CHECK_INTERVAL:
        _spawn_background_check()


def clear_cache() -> None:
    """Remove the cache file so the next launch does a fresh check."""
    try:
        _CACHE_FILE.unlink(missing_ok=True)
    except OSError:
        pass


def _spawn_background_check() -> None:
    """Fire-and-forget a detached subprocess to update the cache."""
    script = f"""
import json, time, urllib.request, re, pathlib
try:
    req = urllib.request.Request("{_GITHUB_API}", headers={{"User-Agent": "td-cli"}})
    resp = urllib.request.urlopen(req, timeout=5)
    data = resp.read().decode()
    m = re.search(r'"tag_name":\\s*"([^"]+)"', data)
    if m:
        latest = m.group(1).lstrip("v")
        cache_path = pathlib.Path("{_CACHE_FILE}")
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps({{"latest": latest, "checked_at": time.time()}}))
except Exception:
    pass
"""
    try:
        subprocess.Popen(
            [sys.executable, "-c", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass
