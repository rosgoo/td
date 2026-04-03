"""Generate an HTML calendar view linking to weekly summaries."""

import os
import re
import subprocess
from datetime import datetime, timedelta
from html import escape
from pathlib import Path

from td_cli.config import console
from td_cli.weekly import SUMMARY_DIR

# ---------------------------------------------------------------------------
# Data extraction from existing weekly summaries
# ---------------------------------------------------------------------------


def _extract_stats_from_html(path: Path) -> dict:
    """Pull stats, task titles, and per-day stats from a weekly summary HTML."""
    text = path.read_text()

    stats = {}
    for m in re.finditer(
        r'<div class="number"[^>]*>(\d+)</div>\s*<div class="label">([^<]+)</div>',
        text,
    ):
        val, label = int(m.group(1)), m.group(2).strip().lower()
        stats[label] = val

    tasks = []
    for m in re.finditer(r'<h3>([^<]+)\s*<span class="badge (\w+)">', text):
        title, badge = m.group(1).strip(), m.group(2)
        tasks.append({"title": title, "status": badge})

    merged_prs = []
    for m in re.finditer(
        r'<a href="[^"]*">#(\d+)</a>\s*<span class="pr-title">([^<]+)</span>\s*<span class="badge merged">',
        text,
    ):
        merged_prs.append({"number": int(m.group(1)), "title": m.group(2).strip()})

    date_range = ""
    m = re.search(r'<div class="date-range">([^<]+)</div>', text)
    if m:
        date_range = m.group(1).split("·")[0].strip()

    # Per-day stats: split HTML by day sections (id="day-YYYY-MM-DD")
    day_stats: dict[str, dict] = {}
    day_sections = re.split(r'<div class="day" id="day-(\d{4}-\d{2}-\d{2})">', text)
    # day_sections[0] is before first day, then alternating: date_str, section_html
    for i in range(1, len(day_sections) - 1, 2):
        date_str = day_sections[i]
        section = (
            day_sections[i + 1].split("</div>\n</div>")[0]
            if i + 1 < len(day_sections)
            else ""
        )
        n_tasks = len(re.findall(r'<div class="card">', section))
        n_merged = len(re.findall(r'class="badge merged">', section))
        n_reviewed = len(re.findall(r'class="badge reviewed">', section))
        # Task titles for hover preview
        task_titles = []
        for tm in re.finditer(r'<h3>([^<]+)\s*<span class="badge (\w+)">', section):
            task_titles.append({"title": tm.group(1).strip(), "status": tm.group(2)})
        day_stats[date_str] = {
            "tasks": n_tasks,
            "merged": n_merged,
            "reviewed": n_reviewed,
            "task_titles": task_titles,
        }

    # Session time (non-numeric stat like "5h23m")
    session_time = ""
    m = re.search(
        r'<div class="number"[^>]*>([^<]+)</div>\s*<div class="label">Session Time</div>',
        text,
    )
    if m:
        session_time = m.group(1).strip()

    return {
        "tasks_done": stats.get("tasks done", 0),
        "in_progress": stats.get("in progress", 0),
        "prs_merged": stats.get("prs merged", 0),
        "prs_opened": stats.get("prs opened", 0),
        "prs_reviewed": stats.get("prs reviewed", 0),
        "session_time": session_time,
        "tasks": tasks,
        "merged_prs": merged_prs,
        "date_range": date_range,
        "day_stats": day_stats,
        "file": str(path),
    }


def _find_summaries() -> dict[str, dict]:
    """Find all weekly summary HTML files and extract their stats.

    Returns a dict keyed by the ISO date string from the filename.
    """
    results = {}
    if not SUMMARY_DIR.is_dir():
        return results
    for f in sorted(SUMMARY_DIR.glob("weekly-summary-*.html")):
        m = re.search(r"weekly-summary-(\d{4}-\d{2}-\d{2})\.html$", f.name)
        if m:
            date_str = m.group(1)
            results[date_str] = _extract_stats_from_html(f)
    return results


def _week_start(dt: datetime) -> datetime:
    """Return the Monday of the week containing dt."""
    return (dt - timedelta(days=dt.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------


def _e(text: str) -> str:
    return escape(text)


def _render_week_pill(wd: dict | None) -> str:
    """Render a week summary cell (no hover — hover is on day cells now)."""
    if not wd:
        return '<td class="week-summary-cell"><span class="no-summary">—</span></td>'
    summary_file = f"weekly-summary-{wd['summary_date']}.html"
    time_html = ""
    if wd.get("session_time") and wd["session_time"] != "—":
        time_html = f'<span class="ws-time">{_e(wd["session_time"])}</span>'
    return (
        f'<td class="week-summary-cell">'
        f'<a href="{_e(summary_file)}" class="week-link">'
        f'<span class="week-stats">'
        f'<span class="ws-done">{wd["tasks_done"]} done</span>'
        f'<span class="ws-active">{wd["in_progress"]} active</span>'
        f'<span class="ws-pr">{wd["prs_merged"]} prs</span>'
        f'{time_html}'
        f"</span>"
        f"</a></td>"
    )


def generate_calendar_html(months: int = 3) -> str:
    """Generate a calendar HTML page covering the last N months."""
    summaries = _find_summaries()
    now = datetime.now()
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)

    # Map each summary to its week-start (Monday)
    week_data: dict[str, dict] = {}
    for date_str, stats in summaries.items():
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        ws = _week_start(dt)
        ws_key = ws.strftime("%Y-%m-%d")
        week_data[ws_key] = {**stats, "summary_date": date_str}

    # Generate month grids
    months_html = []
    current = today.replace(day=1)
    for _ in range(months):
        month_name = current.strftime("%B %Y")
        # Find all days in this month
        year, month = current.year, current.month
        next_month = (current.replace(day=28) + timedelta(days=4)).replace(day=1)

        # Build week rows
        day = current
        # Pad to start on Monday
        start_weekday = day.weekday()  # 0=Mon

        weeks_html = []
        week_days = []

        # Pad beginning
        for _ in range(start_weekday):
            week_days.append('<td class="day-cell empty"></td>')

        while day < next_month:
            is_today = day.date() == today.date()
            day_num = day.day
            ws = _week_start(day)
            ws_key = ws.strftime("%Y-%m-%d")
            has_summary = ws_key in week_data

            classes = ["day-cell"]
            if is_today:
                classes.append("today")
            if has_summary and day.weekday() == 0:
                classes.append("week-start")

            day_str = day.strftime("%Y-%m-%d")
            wd = week_data.get(ws_key)
            ds = wd["day_stats"].get(day_str) if wd else None
            has_activity = ds and (ds["tasks"] or ds["merged"] or ds["reviewed"])

            if has_activity:
                classes.append("has-activity")
                summary_file = f"weekly-summary-{wd['summary_date']}.html"
                day_link = f"{summary_file}#day-{day_str}"
                dots = []
                if ds["tasks"]:
                    dots.append(f'<span class="dot-tasks">{ds["tasks"]}</span>')
                if ds["merged"]:
                    dots.append(f'<span class="dot-prs">{ds["merged"]}</span>')
                if ds["reviewed"]:
                    dots.append(f'<span class="dot-reviews">{ds["reviewed"]}</span>')
                dot_html = f'<div class="day-dots">{" ".join(dots)}</div>'
                # Hover preview
                hover_items = "".join(
                    f'<div class="tt-task"><span class="tt-badge {t["status"]}">{t["status"]}</span> {_e(t["title"][:45])}</div>'
                    for t in ds.get("task_titles", [])[:6]
                )
                if len(ds.get("task_titles", [])) > 6:
                    hover_items += f'<div class="tt-more">+{len(ds["task_titles"]) - 6} more</div>'
                hover_html = f'<div class="day-hover">{hover_items}</div>' if hover_items else ""
                week_days.append(
                    f'<td class="{" ".join(classes)}">'
                    f'<a href="{_e(day_link)}" class="day-link">'
                    f'<span class="day-num">{day_num}</span>'
                    f"{dot_html}"
                    f"{hover_html}"
                    f"</a></td>"
                )
            else:
                week_days.append(
                    f'<td class="{" ".join(classes)}">'
                    f'<span class="day-num">{day_num}</span>'
                    f"</td>"
                )

            if day.weekday() == 6:  # Sunday = end of week row
                ws_key = _week_start(day).strftime("%Y-%m-%d")
                wd = week_data.get(ws_key)
                week_summary = _render_week_pill(wd)
                weeks_html.append(f"<tr>{''.join(week_days)}{week_summary}</tr>")
                week_days = []

            day += timedelta(days=1)

        # Pad end of last week
        if week_days:
            remaining = 7 - len(week_days)
            for _ in range(remaining):
                week_days.append('<td class="day-cell empty"></td>')
            ws_key = _week_start(day - timedelta(days=1)).strftime("%Y-%m-%d")
            wd = week_data.get(ws_key)
            week_summary = _render_week_pill(wd)
            weeks_html.append(f"<tr>{''.join(week_days)}{week_summary}</tr>")

        months_html.append(
            f'<div class="month">'
            f"<h2>{_e(month_name)}</h2>"
            f"<table>"
            f"<thead><tr>"
            f'<th>Mon</th><th>Tue</th><th>Wed</th><th>Thu</th><th>Fri</th><th class="weekend">Sat</th><th class="weekend">Sun</th>'
            f'<th class="week-col">Week</th>'
            f"</tr></thead>"
            f"<tbody>{''.join(weeks_html)}</tbody>"
            f"</table>"
            f"</div>"
        )

        # Go to previous month
        current = (current - timedelta(days=1)).replace(day=1)

    # Overall stats
    total_done = sum(s.get("tasks_done", 0) for s in summaries.values())
    total_merged = sum(s.get("prs_merged", 0) for s in summaries.values())
    total_reviewed = sum(s.get("prs_reviewed", 0) for s in summaries.values())
    n_weeks = len(summaries)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Activity Calendar</title>
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
    padding: 2rem; max-width: 1000px; margin: 0 auto;
  }}
  header {{ margin-bottom: 2rem; padding-bottom: 1.5rem; border-bottom: 1px solid var(--border); }}
  .logo {{
    color: var(--accent); font-size: 0.7rem; line-height: 1.15; margin: 0 0 0.4rem;
    font-family: monospace; text-align: left;
  }}
  header .subtitle {{ color: var(--text-muted); font-size: 0.95rem; }}

  .stats-bar {{ display: flex; gap: 1.5rem; margin: 1.5rem 0 2rem; flex-wrap: wrap; }}
  .stat {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem 1.25rem; min-width: 130px; }}
  .stat .number {{ font-size: 1.75rem; font-weight: 700; line-height: 1.2; }}
  .stat .label {{ color: var(--text-muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em; }}

  .month {{ margin-bottom: 2.5rem; }}
  .month h2 {{ font-size: 1.1rem; font-weight: 600; margin-bottom: 0.75rem; color: var(--text); }}

  table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
  th {{
    font-size: 0.72rem; color: var(--text-muted); font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.04em; padding: 0.4rem 0.3rem; text-align: center;
  }}
  th.weekend {{ color: #484f58; }}
  th.week-col {{ width: 180px; text-align: left; padding-left: 0.75rem; }}

  .day-cell {{
    height: 52px; text-align: center; vertical-align: middle;
    border: 1px solid transparent; border-radius: 6px; position: relative;
  }}
  .day-cell .day-num {{ font-size: 0.82rem; color: var(--text-muted); }}
  .day-cell.empty .day-num {{ visibility: hidden; }}
  .day-cell.today {{
    background: var(--accent-subtle); border-color: var(--accent);
  }}
  .day-cell.today .day-num {{ color: var(--accent); font-weight: 700; }}
  .day-cell.has-activity {{ background: var(--surface); }}
  .day-link {{
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    text-decoration: none; height: 100%; border-radius: 6px;
    transition: background 0.15s;
  }}
  .day-link:hover {{ background: var(--surface-hover); }}
  .day-link .day-num {{ color: var(--text); font-weight: 600; }}
  .day-dots {{
    display: flex; gap: 0.3rem; font-size: 0.6rem; font-weight: 600;
    font-variant-numeric: tabular-nums; margin-top: 0.1rem;
  }}
  .dot-tasks {{ color: var(--green); }}
  .dot-prs {{ color: var(--purple); }}
  .dot-reviews {{ color: var(--text-muted); }}

  .week-summary-cell {{
    vertical-align: middle; padding: 0.25rem 0.5rem; position: relative;
  }}
  .week-link {{
    display: block; text-decoration: none; padding: 0.4rem 0.6rem;
    border-radius: 6px; border: 1px solid var(--border); background: var(--surface);
    transition: border-color 0.15s, background 0.15s; position: relative;
  }}
  .week-link:hover {{
    border-color: var(--accent); background: var(--surface-hover);
  }}
  .week-stats {{
    display: flex; gap: 0.5rem; font-size: 0.75rem; font-weight: 600;
    font-variant-numeric: tabular-nums;
  }}
  .ws-done {{ color: var(--green); }}
  .ws-active {{ color: var(--yellow); }}
  .ws-pr {{ color: var(--purple); }}
  .ws-time {{ color: var(--yellow); }}

  .no-summary {{ color: #30363d; font-size: 0.8rem; }}

  /* Hover tooltip on day cells */
  .day-hover {{
    display: none; position: absolute; left: 50%; top: 100%; margin-top: 0.25rem;
    transform: translateX(-50%);
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.6rem; min-width: 260px; max-width: 350px; z-index: 100;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4); text-align: left;
  }}
  .day-link:hover .day-hover {{ display: block; }}

  .tt-task {{
    font-size: 0.78rem; color: var(--text-muted); padding: 0.15rem 0;
    display: flex; align-items: center; gap: 0.4rem;
  }}
  .tt-badge {{
    display: inline-block; font-size: 0.6rem; font-weight: 600; padding: 0.1em 0.4em;
    border-radius: 8px; text-transform: uppercase; letter-spacing: 0.03em;
  }}
  .tt-badge.done {{ background: var(--green-subtle); color: var(--green); }}
  .tt-badge.active {{ background: var(--yellow-subtle); color: var(--yellow); }}
  .tt-pr {{
    font-size: 0.75rem; color: var(--purple); padding: 0.1rem 0;
  }}
  .tt-more {{ font-size: 0.72rem; color: #484f58; padding-top: 0.2rem; }}

  footer {{ margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--text-muted); font-size: 0.8rem; text-align: center; }}
</style>
</head>
<body>

<header>
  <pre class="logo">  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄
    █    █   █ █    █ █   █
    █    █   █ █    █ █   █
    █    █▄▄▄█ █▄▄▄▀  █▄▄▄█</pre>
  <div class="subtitle">{n_weeks} week{"s" if n_weeks != 1 else ""} tracked</div>
</header>

<div class="stats-bar">
  <div class="stat"><div class="number" style="color:var(--green)">{total_done}</div><div class="label">Total Done</div></div>
  <div class="stat"><div class="number" style="color:var(--purple)">{total_merged}</div><div class="label">Total PRs</div></div>
  <div class="stat"><div class="number" style="color:var(--text-muted)">{total_reviewed}</div><div class="label">Total Reviews</div></div>
  <div class="stat"><div class="number" style="color:var(--accent)">{n_weeks}</div><div class="label">Weeks</div></div>
</div>

{"".join(months_html)}

<footer>
  Generated {datetime.now().strftime("%B %-d, %Y at %-I:%M %p")}
</footer>

</body>
</html>"""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(months: int = 3) -> None:
    """Generate calendar view and open in browser."""
    console.print("[dim]Scanning weekly summaries...[/]")
    html = generate_calendar_html(months)

    SUMMARY_DIR.mkdir(parents=True, exist_ok=True)
    out_path = SUMMARY_DIR / "calendar.html"
    out_path.write_text(html)

    summaries = _find_summaries()
    console.print(f"\n[green]✓[/] {out_path}")
    console.print(f"  {len(summaries)} weekly summaries found")

    if subprocess.run(["which", "open"], capture_output=True).returncode == 0:
        subprocess.run(["open", str(out_path)])
