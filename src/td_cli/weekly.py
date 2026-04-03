"""Generate an HTML weekly summary of tasks and PRs organized by day."""

import base64
import glob as _glob
import json
import os
import subprocess
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from html import escape
from pathlib import Path

import re as _re

from td_cli.config import DATA_DIR, DONE_DIR, LINEAR_ORG, NOTES_DIR, console

SUMMARY_DIR = DATA_DIR / "summary"

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------


def _read_todos() -> list[dict]:
    todos_file = DATA_DIR / "todos.json"
    try:
        return json.loads(todos_file.read_text())
    except (json.JSONDecodeError, FileNotFoundError):
        return []


def _find_session_file(session_id: str) -> str | None:
    """Locate a Claude session JSONL file."""
    base = os.path.expanduser("~/.claude/projects")
    for match in _glob.glob(f"{base}/*/{session_id}.jsonl"):
        if "subagent" not in match:
            return match
    return None


def _session_mtime(session_id: str) -> datetime | None:
    """Return the modification time of a Claude session file, or None."""
    path = _find_session_file(session_id)
    if path:
        return datetime.fromtimestamp(os.path.getmtime(path))
    return None


def _session_duration_minutes(session_id: str, idle_threshold: float = 5.0) -> float | None:
    """Calculate active session time by summing inter-message gaps under threshold.

    Only counts gaps between consecutive timestamps that are shorter than
    idle_threshold minutes. Longer gaps = idle/away time, excluded.
    """
    path = _find_session_file(session_id)
    if not path:
        return None
    try:
        timestamps: list[datetime] = []
        with open(path) as f:
            for line in f:
                try:
                    obj = json.loads(line)
                    ts = obj.get("timestamp")
                    if ts:
                        timestamps.append(
                            datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        )
                except json.JSONDecodeError:
                    continue
        if len(timestamps) < 2:
            return None
        active = 0.0
        for i in range(1, len(timestamps)):
            gap = (timestamps[i] - timestamps[i - 1]).total_seconds() / 60
            if gap <= idle_threshold:
                active += gap
        return active if active > 0 else None
    except OSError:
        pass
    return None


def _git_diff_stats(branch: str, repos: list[str]) -> dict | None:
    """Get +/- line counts for a branch vs master/main."""
    if not branch:
        return None
    for repo_slug in repos:
        # Try to find local repo path from worktree dirs
        pass
    # Try from common repo locations
    for repo_path in _repo_paths:
        try:
            # Determine base branch
            base = "master"
            if subprocess.run(
                ["git", "-C", repo_path, "show-ref", "--verify", "--quiet", "refs/heads/master"],
                capture_output=True,
            ).returncode != 0:
                base = "main"
            # Check branch exists
            if subprocess.run(
                ["git", "-C", repo_path, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
                capture_output=True,
            ).returncode != 0:
                continue
            result = subprocess.run(
                ["git", "-C", repo_path, "diff", f"{base}...{branch}", "--shortstat"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode != 0:
                continue
            line = result.stdout.strip()
            if not line:
                continue
            adds = 0
            dels = 0
            m = _re.search(r"(\d+) insertion", line)
            if m:
                adds = int(m.group(1))
            m = _re.search(r"(\d+) deletion", line)
            if m:
                dels = int(m.group(1))
            return {"additions": adds, "deletions": dels}
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            continue
    return None


# Cache of discovered repo paths on disk
_repo_paths: list[str] = []


def _discover_repo_paths(tasks: list[dict]) -> None:
    """Find local git repo root paths from task worktree/session paths."""
    global _repo_paths
    seen: set[str] = set()
    for task in tasks:
        for key in ("worktree_path", "session_cwd"):
            d = task.get(key, "")
            if not d:
                continue
            p = Path(d)
            while p != p.parent:
                if (p / ".git").exists() or (p / ".git").is_file():
                    s = str(p)
                    if s not in seen:
                        seen.add(s)
                        _repo_paths.append(s)
                    break
                p = p.parent


def _extract_linear_ticket(title: str) -> str | None:
    """Extract a Linear ticket ID like CORE-12345 from a task title."""
    m = _re.search(r"\b([A-Z]+-\d+)\b", title)
    return m.group(1) if m else None


def _linear_url(ticket_id: str) -> str:
    """Build a Linear ticket URL."""
    if LINEAR_ORG and ticket_id:
        return f"https://linear.app/{LINEAR_ORG}/issue/{ticket_id.lower()}"
    return ""


def _format_duration(minutes: float | None) -> str:
    """Format minutes as a human-readable string."""
    if minutes is None:
        return ""
    if minutes < 60:
        return f"{int(minutes)}m"
    h = int(minutes // 60)
    m = int(minutes % 60)
    return f"{h}h{m}m" if m else f"{h}h"


def _gh_json(args: list[str], repo: str = "") -> list[dict]:
    """Run a gh command that returns JSON, return parsed list.

    If repo is given (e.g. "Maybern/maybern"), adds -R flag so the command
    works regardless of the current working directory.
    """
    cmd = ["gh"] + args
    if repo and "-R" not in args:
        cmd = ["gh"] + args[:2] + ["-R", repo] + args[2:]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        pass
    return []


def _detect_repos(tasks: list[dict]) -> list[str]:
    """Detect GitHub repo slugs (owner/name) from task worktree paths."""
    repos = set()
    # Check worktree paths and session cwds for git remotes
    seen_dirs: set[str] = set()
    for task in tasks:
        for key in ("worktree_path", "session_cwd"):
            d = task.get(key, "")
            if not d or d in seen_dirs:
                continue
            seen_dirs.add(d)
            # Walk up to find a git root
            p = Path(d)
            while p != p.parent:
                if (p / ".git").exists() or (p / ".git").is_file():
                    break
                p = p.parent
            else:
                continue
            try:
                url = subprocess.run(
                    ["git", "-C", str(p), "remote", "get-url", "origin"],
                    capture_output=True, text=True, timeout=5,
                ).stdout.strip()
                # Parse owner/name from git URL
                url = url.removesuffix(".git")
                if "github.com" in url:
                    slug = url.split("github.com")[-1].lstrip("/:")
                    if "/" in slug:
                        repos.add(slug)
            except (subprocess.TimeoutExpired, FileNotFoundError):
                pass
    # Fallback: try current directory
    if not repos:
        try:
            result = subprocess.run(
                ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0 and result.stdout.strip():
                repos.add(result.stdout.strip())
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
    return sorted(repos)


def _git_user() -> str:
    try:
        return (
            subprocess.run(
                ["git", "config", "user.name"],
                capture_output=True,
                text=True,
            ).stdout.strip()
            or "Unknown"
        )
    except FileNotFoundError:
        return "Unknown"


def _gh_login() -> str:
    try:
        result = subprocess.run(
            ["gh", "api", "user", "--jq", ".login"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def _read_summary(task: dict) -> str:
    """Read the first paragraph of summary.md for a task, if it exists."""
    notes_path = task.get("notes_path", "")
    if not notes_path:
        return ""
    summary_file = Path(notes_path).parent / "summary.md"
    if not summary_file.exists():
        return ""
    lines = summary_file.read_text().splitlines()
    # Skip title and blank lines, grab first content paragraph
    content_lines = []
    in_content = False
    for line in lines:
        if (
            line.startswith("# ")
            or line.startswith("**Date")
            or line.startswith("**Branch")
            or line.startswith("**Status")
            or line.startswith("**Ticket")
        ):
            continue
        if line.startswith("## Summary") or line.startswith("## What was done"):
            in_content = True
            continue
        if in_content:
            if line.startswith("##") or line.startswith("###"):
                break
            if line.strip():
                content_lines.append(line.strip())
            elif content_lines:
                break  # end of first paragraph
    return " ".join(content_lines)[:300]


def _read_full_md(task: dict, filename: str) -> str:
    """Read the full contents of a markdown file next to the task's plan."""
    notes_path = task.get("notes_path", "")
    if not notes_path:
        return ""
    target = Path(notes_path).parent / filename
    if not target.exists():
        return ""
    return target.read_text()


def _utc_to_local(iso_str: str) -> datetime:
    """Parse a GitHub UTC timestamp to local datetime."""
    # Handle both 'Z' and '+00:00' suffixes
    iso_str = iso_str.replace("Z", "+00:00")
    dt = datetime.fromisoformat(iso_str)
    return dt.astimezone(tz=None)


def _date_key(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d")


def _weekday_name(dt: datetime) -> str:
    return dt.strftime("%A")


def _format_date(dt: datetime) -> str:
    return dt.strftime("%B %-d")


# ---------------------------------------------------------------------------
# Core collection
# ---------------------------------------------------------------------------


def _week_start(dt: datetime) -> datetime:
    """Return the Monday of the week containing dt."""
    return (dt - timedelta(days=dt.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )


def collect_data_for_week(monday: datetime) -> dict:
    """Collect all tasks, PRs, and session data for a single Mon-Sun week."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    start = monday
    end = min(monday + timedelta(days=6), today)  # Sun or today if mid-week
    start_str = start.strftime("%Y-%m-%d")
    end_str = end.strftime("%Y-%m-%d")

    # --- Tasks ---
    all_todos = _read_todos()
    week_tasks = []
    missing_summaries = []

    for task in all_todos:
        created = (task.get("created_at") or "")[:10]
        opened = (task.get("last_opened_at") or "")[:10]
        if not (
            (created >= start_str and created <= end_str)
            or (opened >= start_str and opened <= end_str)
        ):
            continue

        # Check if actually worked on (session active in range)
        session_id = task.get("session_id", "")
        session_dt = None
        if session_id:
            session_dt = _session_mtime(session_id)

        active_this_period = False
        if session_dt and session_dt.strftime("%Y-%m-%d") >= start_str:
            active_this_period = True

        # Will also check PR activity below
        task["_session_dt"] = session_dt
        task["_active"] = active_this_period
        task["_summary"] = _read_summary(task)
        task["_summary_full"] = _read_full_md(task, "summary.md")
        task["_plan_full"] = _read_full_md(task, "plan.md")

        # Session duration
        if session_id:
            task["_duration_min"] = _session_duration_minutes(session_id)
        else:
            task["_duration_min"] = None

        # Linear ticket
        ticket = _extract_linear_ticket(task.get("title", ""))
        task["_linear_ticket"] = ticket
        task["_linear_url"] = _linear_url(ticket) if ticket else ""

        # Check for missing summaries on active tasks
        notes_path = task.get("notes_path", "")
        if active_this_period and notes_path:
            summary_file = Path(notes_path).parent / "summary.md"
            if not summary_file.exists():
                missing_summaries.append(task["title"])

        week_tasks.append(task)

    # --- Detect repos from task data ---
    repos = _detect_repos(week_tasks + all_todos)

    # --- PRs authored (merged) — query each repo ---
    authored_merged: list[dict] = []
    for repo in repos:
        authored_merged.extend(
            _gh_json(
                [
                    "pr", "list", "--state", "merged", "--author", "@me",
                    "--search", f"merged:>={start_str}",
                    "--json", "number,title,mergedAt,url,additions,deletions,headRefName",
                    "--limit", "50",
                ],
                repo=repo,
            )
        )

    # --- PRs authored (open) ---
    authored_open: list[dict] = []
    for repo in repos:
        authored_open.extend(
            _gh_json(
                [
                    "pr", "list", "--state", "open", "--author", "@me",
                    "--json", "number,title,createdAt,url,additions,deletions,headRefName,isDraft",
                    "--limit", "20",
                ],
                repo=repo,
            )
        )
    # Filter to ones created in range
    authored_open = [
        pr for pr in authored_open
        if _utc_to_local(pr["createdAt"]).strftime("%Y-%m-%d") >= start_str
    ]

    # --- PRs reviewed ---
    my_login = _gh_login()
    reviewed: list[dict] = []
    for repo in repos:
        reviewed.extend(
            _gh_json(
                [
                    "pr", "list", "--state", "merged",
                    "--search", f"reviewed-by:@me merged:>={start_str}",
                    "--json", "number,title,mergedAt,url,author,additions,deletions",
                    "--limit", "50",
                ],
                repo=repo,
            )
        )
    # Remove own PRs from reviewed list
    if my_login:
        reviewed = [
            pr for pr in reviewed if pr.get("author", {}).get("login", "") != my_login
        ]

    # --- Map PRs to tasks by branch ---
    branch_to_task = {}
    for task in week_tasks:
        branch = task.get("branch", "")
        if branch:
            branch_to_task[branch] = task["id"]

    for pr in authored_merged + authored_open:
        branch = pr.get("headRefName", "")
        task_id = branch_to_task.get(branch)
        if task_id:
            pr["_task_id"] = task_id
            # Mark task as active if it has a merged PR in range
            for task in week_tasks:
                if task["id"] == task_id and not task["_active"]:
                    task["_active"] = True

    # Filter out cleanup-only tasks
    week_tasks = [t for t in week_tasks if t["_active"]]

    # --- Git diff stats (after filtering to avoid unnecessary git calls) ---
    _discover_repo_paths(week_tasks + all_todos)
    for task in week_tasks:
        task["_diff_stats"] = _git_diff_stats(task.get("branch", ""), repos)

    # --- Subtask grouping ---
    by_id = {t["id"]: t for t in week_tasks}
    for task in week_tasks:
        pid = task.get("parent_id", "")
        task["_is_subtask"] = bool(pid and pid in by_id)
        task["_children"] = [
            t for t in week_tasks if t.get("parent_id") == task["id"]
        ]

    # --- Assign to days ---
    task_by_day: dict[str, list[dict]] = defaultdict(list)
    for task in week_tasks:
        session_dt = task.get("_session_dt")
        if session_dt and session_dt.strftime("%Y-%m-%d") >= start_str:
            day = _date_key(session_dt)
        elif task.get("last_opened_at"):
            day = _utc_to_local(task["last_opened_at"]).strftime("%Y-%m-%d")
        else:
            day = (task.get("created_at") or "")[:10]
        task_by_day[day].append(task)

    merged_by_day: dict[str, list[dict]] = defaultdict(list)
    for pr in authored_merged:
        day = _date_key(_utc_to_local(pr["mergedAt"]))
        merged_by_day[day].append(pr)

    opened_by_day: dict[str, list[dict]] = defaultdict(list)
    for pr in authored_open:
        day = _date_key(_utc_to_local(pr["createdAt"]))
        opened_by_day[day].append(pr)

    reviewed_by_day: dict[str, list[dict]] = defaultdict(list)
    for pr in reviewed:
        day = _date_key(_utc_to_local(pr["mergedAt"]))
        reviewed_by_day[day].append(pr)

    # Build day list
    days = []
    d = start
    while d <= end:
        dk = _date_key(d)
        days.append(
            {
                "date": dk,
                "weekday": _weekday_name(d),
                "display": _format_date(d),
                "tasks": task_by_day.get(dk, []),
                "merged": merged_by_day.get(dk, []),
                "opened": opened_by_day.get(dk, []),
                "reviewed": reviewed_by_day.get(dk, []),
            }
        )
        d += timedelta(days=1)

    return {
        "user": _git_user(),
        "start": start,
        "end": end,
        "week_start": monday,
        "days": days,
        "tasks": week_tasks,
        "authored_merged": authored_merged,
        "authored_open": authored_open,
        "reviewed": reviewed,
        "missing_summaries": missing_summaries,
        "total_duration_min": sum(
            t.get("_duration_min") or 0 for t in week_tasks
        ),
    }


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------


def _e(text: str) -> str:
    return escape(text)


def _badge(label: str, cls: str) -> str:
    return f'<span class="badge {cls}">{_e(label)}</span>'


def _task_badge(task: dict) -> str:
    status = task.get("status", "active")
    if status == "done":
        return _badge("done", "done")
    return _badge("active", "active")


def _pr_stats(pr: dict) -> str:
    add = pr.get("additions", 0)
    sub = pr.get("deletions", 0)
    return f'<span class="pr-stats"><span class="add">+{add:,}</span> <span class="del">&minus;{sub:,}</span></span>'


def _author_name(pr: dict) -> str:
    author = pr.get("author", {})
    name = author.get("name", "") or author.get("login", "")
    return name.split()[0] if name else "?"


def _render_task_card(task: dict, data: dict, indent: int = 0) -> str:
    """Render a single task card HTML."""
    title = _e(task.get("title", ""))
    badge = _task_badge(task)
    branch = task.get("branch", "")
    summary = task.get("_summary", "")
    tid = _e(task["id"])

    # Meta line: branch, PR, Linear ticket, diff stats, duration
    meta_parts = []
    if task.get("_linear_url"):
        meta_parts.append(
            f'<a href="{_e(task["_linear_url"])}" class="meta-link">{_e(task["_linear_ticket"])}</a>'
        )
    if branch:
        meta_parts.append(f"<code>{_e(branch)}</code>")
    for pr in data["authored_merged"] + data["authored_open"]:
        if pr.get("_task_id") == task["id"]:
            meta_parts.append(
                f'PR <a href="{_e(pr["url"])}" class="meta-link">#{pr["number"]}</a>'
            )
            break
    diff = task.get("_diff_stats")
    if diff:
        meta_parts.append(
            f'<span class="add">+{diff["additions"]:,}</span>'
            f' <span class="del">&minus;{diff["deletions"]:,}</span>'
        )
    dur = _format_duration(task.get("_duration_min"))
    if dur:
        meta_parts.append(f'<span class="duration">{dur}</span>')

    meta_html = ""
    if meta_parts:
        meta_html = f'<div class="meta">{" &middot; ".join(meta_parts)}</div>'

    summary_html = ""
    if summary:
        summary_html = f"<p>{_e(summary)}</p>"

    summary_full = task.get("_summary_full", "")
    plan_full = task.get("_plan_full", "")
    expand_body = ""
    plan_btn = ""

    if summary_full:
        b64 = base64.b64encode(summary_full.encode()).decode()
        expand_body = (
            f'<div class="expand-body" id="body-{tid}" style="display:none">'
            f'<div class="md-content" data-md="{b64}" id="summary-{tid}"></div>'
            f"</div>"
        )

    if plan_full:
        b64 = base64.b64encode(plan_full.encode()).decode()
        plan_btn = f'<button class="plan-btn" onclick="event.stopPropagation();togglePlan(\'{tid}\')">plan</button>'
        expand_body += (
            f'<div class="md-content plan-content" data-md="{b64}" id="plan-{tid}" style="display:none"></div>'
        )

    card_cls = " expandable" if summary_full else ""
    card_cls += " subtask" if indent > 0 else ""
    card_click = ' onclick="toggleCard(this)"' if summary_full else ""

    return (
        f'<div class="card{card_cls}"{card_click}>'
        f"<h3>{title} {badge} {plan_btn}</h3>"
        f"{meta_html}"
        f"{summary_html}"
        f"{expand_body}"
        f"</div>"
    )


def generate_html(data: dict) -> str:
    user = _e(data["user"])
    start_display = data["start"].strftime("%B %-d")
    end_display = data["end"].strftime("%B %-d, %Y")

    n_done = sum(1 for t in data["tasks"] if t.get("status") == "done")
    n_active = sum(1 for t in data["tasks"] if t.get("status") == "active")
    n_merged = len(data["authored_merged"])
    n_opened = len(data["authored_open"])
    n_reviewed = len(data["reviewed"])
    total_dur = data.get("total_duration_min", 0)
    total_dur_str = _format_duration(total_dur) if total_dur else "—"

    # Time chart data: tasks sorted by duration
    time_chart_tasks = sorted(
        [t for t in data["tasks"] if (t.get("_duration_min") or 0) > 0],
        key=lambda t: t.get("_duration_min", 0),
        reverse=True,
    )
    max_dur = time_chart_tasks[0]["_duration_min"] if time_chart_tasks else 1
    time_bars = []
    for t in time_chart_tasks[:15]:  # top 15
        dur = t["_duration_min"]
        pct = min(100, (dur / max_dur) * 100)
        label = _e(t["title"][:40])
        dur_str = _format_duration(dur)
        color = "var(--green)" if t.get("status") == "done" else "var(--yellow)"
        time_bars.append(
            f'<div class="time-row">'
            f'<span class="time-label">{label}</span>'
            f'<div class="time-bar-bg"><div class="time-bar" style="width:{pct:.0f}%;background:{color}"></div></div>'
            f'<span class="time-val">{dur_str}</span>'
            f"</div>"
        )
    time_chart_html = "\n".join(time_bars) if time_bars else '<div style="color:var(--text-muted);font-size:0.85rem">No session data available</div>'

    days_html = []
    for day in data["days"]:
        has_content = day["tasks"] or day["merged"] or day["opened"] or day["reviewed"]
        sections = []

        # Merged PRs
        if day["merged"]:
            rows = []
            for pr in day["merged"]:
                rows.append(
                    f'<div class="pr-row">'
                    f'<a href="{_e(pr["url"])}">#{pr["number"]}</a>'
                    f'<span class="pr-title">{_e(pr["title"])}</span>'
                    f"{_badge('merged', 'merged')}"
                    f"{_pr_stats(pr)}"
                    f"</div>"
                )
            sections.append(
                '<div class="subsection">PRs Merged</div>' + "\n".join(rows)
            )

        # Opened PRs
        if day["opened"]:
            rows = []
            for pr in day["opened"]:
                cls = "draft" if pr.get("isDraft") else "opened"
                label = "draft" if pr.get("isDraft") else "open"
                rows.append(
                    f'<div class="pr-row">'
                    f'<a href="{_e(pr["url"])}">#{pr["number"]}</a>'
                    f'<span class="pr-title">{_e(pr["title"])}</span>'
                    f"{_badge(label, cls)}"
                    f"{_pr_stats(pr)}"
                    f"</div>"
                )
            sections.append(
                '<div class="subsection">PRs Opened</div>' + "\n".join(rows)
            )

        # Tasks (skip subtasks at top level — they render under parents)
        if day["tasks"]:
            cards = []
            for task in day["tasks"]:
                if task.get("_is_subtask"):
                    continue
                cards.append(_render_task_card(task, data, indent=0))
                for child in task.get("_children", []):
                    cards.append(_render_task_card(child, data, indent=1))
            if cards:
                sections.append('<div class="subsection">Tasks</div>' + "\n".join(cards))

        # Reviewed PRs
        if day["reviewed"]:
            rows = []
            for pr in day["reviewed"]:
                rows.append(
                    f'<div class="pr-row">'
                    f'<a href="{_e(pr["url"])}">#{pr["number"]}</a>'
                    f'<span class="pr-title">{_e(pr["title"])}</span>'
                    f'<span class="pr-author">{_e(_author_name(pr))}</span>'
                    f"{_badge('reviewed', 'reviewed')}"
                    f"</div>"
                )
            sections.append(
                '<div class="subsection">PRs Reviewed</div>' + "\n".join(rows)
            )

        content = "\n".join(sections)
        if not has_content:
            content = '<div class="card" style="border-color: var(--border); opacity: 0.6;"><p style="text-align: center; color: var(--text-muted); padding: 0.5rem 0;">No recorded activity</p></div>'

        days_html.append(
            f'<div class="day" id="day-{day["date"]}">\n'
            f'<div class="day-header">'
            f'<span class="weekday">{_e(day["weekday"])}</span>'
            f'<span class="date">{_e(day["display"])}</span>'
            f"</div>\n"
            f"{content}\n"
            f"</div>"
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Weekly Summary — {_e(start_display)} – {_e(end_display)}</title>
<style>
  :root {{
    --bg: #0d1117; --surface: #161b22; --surface-hover: #1c2129;
    --border: #30363d; --text: #e6edf3; --text-muted: #8b949e;
    --accent: #58a6ff; --accent-subtle: #1f6feb22;
    --green: #3fb950; --green-subtle: #23863522;
    --yellow: #d29922; --yellow-subtle: #d2992222;
    --purple: #bc8cff; --purple-subtle: #bc8cff22;
    --red: #f85149;
  }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.6;
    padding: 2rem; max-width: 1100px; margin: 0 auto;
  }}
  header {{ margin-bottom: 2.5rem; padding-bottom: 1.5rem; border-bottom: 1px solid var(--border); }}
  header h1 {{ font-size: 1.75rem; font-weight: 600; margin-bottom: 0.25rem; }}
  header .date-range {{ color: var(--text-muted); font-size: 0.95rem; }}
  .stats-bar {{ display: flex; gap: 1.5rem; margin: 1.5rem 0 2rem; flex-wrap: wrap; }}
  .stat {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem 1.25rem; min-width: 130px; }}
  .stat .number {{ font-size: 1.75rem; font-weight: 700; line-height: 1.2; }}
  .stat .label {{ color: var(--text-muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em; }}
  .day {{ margin-bottom: 2.5rem; scroll-margin-top: 3.5rem; }}
  .day-header {{
    font-size: 1.15rem; font-weight: 600; margin-bottom: 1rem; padding-bottom: 0.5rem;
    border-bottom: 1px solid var(--border); display: flex; align-items: baseline; gap: 0.75rem;
  }}
  .day-header .weekday {{ color: var(--text); }}
  .day-header .date {{ color: var(--text-muted); font-weight: 400; font-size: 0.9rem; }}
  .badge {{
    display: inline-block; font-size: 0.65rem; font-weight: 600; padding: 0.15em 0.5em;
    border-radius: 10px; text-transform: uppercase; letter-spacing: 0.03em; vertical-align: middle;
  }}
  .badge.done {{ background: var(--green-subtle); color: var(--green); }}
  .badge.active {{ background: var(--yellow-subtle); color: var(--yellow); }}
  .badge.merged {{ background: var(--purple-subtle); color: var(--purple); }}
  .badge.opened {{ background: var(--accent-subtle); color: var(--accent); }}
  .badge.draft {{ background: var(--yellow-subtle); color: var(--yellow); }}
  .badge.reviewed {{ background: var(--surface); color: var(--text-muted); border: 1px solid var(--border); }}
  .card {{
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.85rem 1.1rem; margin-bottom: 0.6rem; transition: border-color 0.15s;
  }}
  .card:hover {{ border-color: var(--accent); }}
  .card h3 {{
    font-size: 0.9rem; font-weight: 600; margin-bottom: 0.25rem;
    display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap;
  }}
  .card .meta {{ font-size: 0.78rem; color: var(--text-muted); margin-bottom: 0.35rem; }}
  .card .meta code {{ background: var(--bg); padding: 0.1em 0.4em; border-radius: 4px; font-size: 0.75rem; }}
  .card p {{ font-size: 0.85rem; color: var(--text-muted); line-height: 1.5; }}
  .card.expandable {{ cursor: pointer; }}
  .card.expandable:hover {{ border-color: var(--accent); }}
  .card.expanded {{ border-color: var(--accent); }}
  .expand-body {{ margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid var(--border); }}
  .md-content {{
    font-size: 0.82rem; color: var(--text-muted); line-height: 1.6;
  }}
  .md-content h1, .md-content h2, .md-content h3 {{
    color: var(--text); font-size: 0.88rem; margin: 0.75rem 0 0.35rem;
  }}
  .md-content h1 {{ font-size: 0.95rem; }}
  .md-content code {{
    background: var(--bg); padding: 0.15em 0.4em; border-radius: 4px; font-size: 0.78rem;
  }}
  .md-content pre {{
    background: var(--bg); padding: 0.75rem; border-radius: 6px; overflow-x: auto;
    margin: 0.5rem 0; font-size: 0.78rem;
  }}
  .md-content pre code {{ background: none; padding: 0; }}
  .md-content table {{
    border-collapse: collapse; width: 100%; margin: 0.5rem 0; font-size: 0.78rem;
  }}
  .md-content th, .md-content td {{
    border: 1px solid var(--border); padding: 0.3rem 0.5rem; text-align: left;
  }}
  .md-content th {{ background: var(--bg); color: var(--text); }}
  .md-content ul, .md-content ol {{ margin: 0.3rem 0 0.3rem 1.2rem; }}
  .md-content li {{ margin-bottom: 0.15rem; }}
  .md-content p {{ margin: 0.35rem 0; }}
  .md-content blockquote {{
    border-left: 3px solid var(--border); padding-left: 0.75rem;
    color: var(--text-muted); margin: 0.5rem 0;
  }}
  .plan-btn {{
    font-size: 0.75rem; color: var(--purple); background: none; border: none;
    cursor: pointer; padding: 0; text-decoration: none;
  }}
  .plan-btn:hover {{ text-decoration: underline; }}
  .plan-content {{ margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid var(--border); }}
  .card.subtask {{ margin-left: 1.5rem; border-left: 2px solid var(--border); }}
  .meta-link {{ color: var(--accent); text-decoration: none; }}
  .meta-link:hover {{ text-decoration: underline; }}
  .add {{ color: var(--green); }}
  .del {{ color: var(--red); }}
  .duration {{ color: var(--yellow); }}
  .pr-row {{
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.55rem 1.1rem; margin-bottom: 0.4rem; display: flex;
    align-items: center; gap: 0.75rem; font-size: 0.85rem; transition: border-color 0.15s;
  }}
  .pr-row:hover {{ border-color: var(--accent); }}
  .pr-row a {{ color: var(--accent); text-decoration: none; font-weight: 600; white-space: nowrap; }}
  .pr-row a:hover {{ text-decoration: underline; }}
  .pr-row .pr-title {{ color: var(--text-muted); flex: 1; }}
  .pr-row .pr-author {{ color: var(--text-muted); font-size: 0.78rem; white-space: nowrap; }}
  .pr-row .pr-stats {{ white-space: nowrap; font-size: 0.78rem; font-variant-numeric: tabular-nums; }}
  .subsection {{ margin: 0.75rem 0 0.5rem; font-size: 0.78rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }}
  /* Search */
  .search-bar {{
    margin-bottom: 1.5rem; position: sticky; top: 0; z-index: 10;
    background: var(--bg); padding: 0.5rem 0;
  }}
  .search-bar input {{
    width: 100%; background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 0.6rem 1rem; color: var(--text); font-size: 0.9rem;
    outline: none; transition: border-color 0.15s;
  }}
  .search-bar input:focus {{ border-color: var(--accent); }}
  .search-bar input::placeholder {{ color: #484f58; }}
  /* Time chart */
  .time-chart {{ margin-bottom: 2rem; }}
  .time-chart h2 {{
    font-size: 1rem; font-weight: 600; margin-bottom: 0.75rem;
    padding-bottom: 0.5rem; border-bottom: 1px solid var(--border);
  }}
  .time-row {{ display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.3rem; font-size: 0.8rem; }}
  .time-label {{ width: 250px; color: var(--text-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex-shrink: 0; }}
  .time-bar-bg {{ flex: 1; height: 14px; background: var(--surface); border-radius: 3px; overflow: hidden; }}
  .time-bar {{ height: 100%; border-radius: 3px; min-width: 2px; }}
  .time-val {{ width: 50px; text-align: right; color: var(--text-muted); font-variant-numeric: tabular-nums; flex-shrink: 0; }}
  /* Nav */
  .nav-link {{ color: var(--accent); text-decoration: none; font-size: 0.85rem; }}
  .nav-link:hover {{ text-decoration: underline; }}
  footer {{ margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--text-muted); font-size: 0.8rem; text-align: center; }}
</style>
</head>
<body>

<header>
  <a href="calendar.html" class="nav-link">&larr; Calendar</a>
  <h1>Weekly Summary</h1>
  <div class="date-range">{_e(start_display)} – {_e(end_display)} &middot; {user}</div>
</header>

<div class="stats-bar">
  <div class="stat"><div class="number" style="color:var(--green)">{n_done}</div><div class="label">Tasks Done</div></div>
  <div class="stat"><div class="number" style="color:var(--accent)">{n_active}</div><div class="label">In Progress</div></div>
  <div class="stat"><div class="number" style="color:var(--green)">{n_merged}</div><div class="label">PRs Merged</div></div>
  <div class="stat"><div class="number" style="color:var(--accent)">{n_opened}</div><div class="label">PRs Opened</div></div>
  <div class="stat"><div class="number" style="color:var(--text-muted)">{n_reviewed}</div><div class="label">PRs Reviewed</div></div>
  <div class="stat"><div class="number" style="color:var(--yellow)">{total_dur_str}</div><div class="label">Session Time</div></div>
</div>

<div class="time-chart">
  <h2>Time by task</h2>
  {time_chart_html}
</div>

<div class="search-bar">
  <input type="text" id="search" placeholder="Filter tasks and PRs..." oninput="filterContent(this.value)">
</div>

{"".join(days_html)}

<footer>
  Generated {datetime.now().strftime("%B %-d, %Y at %-I:%M %p")}
</footer>

<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<script>
function toggleCard(card) {{
  const body = card.querySelector('.expand-body');
  if (!body) return;
  const open = body.style.display !== 'none';
  body.style.display = open ? 'none' : 'block';
  card.classList.toggle('expanded', !open);
  if (!open) {{
    body.querySelectorAll('.md-content:not([data-rendered])').forEach(el => {{
      el.innerHTML = marked.parse(atob(el.dataset.md));
      el.setAttribute('data-rendered', '1');
    }});
  }}
}}
function togglePlan(tid) {{
  const el = document.getElementById('plan-' + tid);
  if (!el) return;
  const btn = el.closest('.card').querySelector('.plan-btn');
  if (el.style.display === 'none') {{
    el.style.display = 'block';
    btn.textContent = 'Hide plan';
    if (!el.getAttribute('data-rendered')) {{
      el.innerHTML = marked.parse(atob(el.dataset.md));
      el.setAttribute('data-rendered', '1');
    }}
  }} else {{
    el.style.display = 'none';
    btn.textContent = 'Plan';
  }}
}}
function filterContent(query) {{
  const q = query.toLowerCase();
  document.querySelectorAll('.card, .pr-row').forEach(el => {{
    const text = el.textContent.toLowerCase();
    el.style.display = (!q || text.includes(q)) ? '' : 'none';
  }});
  // Hide empty day sections
  document.querySelectorAll('.day').forEach(day => {{
    const visible = day.querySelectorAll('.card:not([style*="display: none"]), .pr-row:not([style*="display: none"])');
    const header = day.querySelector('.day-header');
    if (header) header.style.display = (!q || visible.length) ? '' : 'none';
  }});
}}
</script>

</body>
</html>"""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(weeks: int = 1) -> None:
    """Generate one weekly summary per week and open the latest in browser."""
    SUMMARY_DIR.mkdir(parents=True, exist_ok=True)

    now = datetime.now()
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    this_monday = _week_start(today)

    last_path = None
    for i in range(weeks - 1, -1, -1):  # oldest first
        target_monday = this_monday - timedelta(weeks=i)
        console.print(
            f"[dim]Collecting week of {target_monday.strftime('%b %-d')}...[/]"
        )
        data = collect_data_for_week(target_monday)

        if data["missing_summaries"]:
            console.print(
                f"  [yellow]{len(data['missing_summaries'])} missing summaries[/]"
            )

        html = generate_html(data)
        monday_str = target_monday.strftime("%Y-%m-%d")
        out_path = SUMMARY_DIR / f"weekly-summary-{monday_str}.html"
        out_path.write_text(html)

        n_tasks = len(data["tasks"])
        n_merged = len(data["authored_merged"])
        n_reviewed = len(data["reviewed"])
        console.print(
            f"  [green]✓[/] {out_path.name}"
            f"  ({n_tasks} tasks · {n_merged} PRs · {n_reviewed} reviews)"
        )
        last_path = out_path

    # Open the latest in browser
    if (
        last_path
        and subprocess.run(["which", "open"], capture_output=True).returncode == 0
    ):
        subprocess.run(["open", str(last_path)])
