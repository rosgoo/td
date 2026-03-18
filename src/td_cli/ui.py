"""Terminal UI helpers: fzf picker, rich prompt wrappers, action menu."""

import subprocess
import sys
from datetime import datetime, timezone

from rich.prompt import Confirm, Prompt

from td_cli.config import console
from td_cli.data import read_todos


# --- Dependency checks ------------------------------------------------------

def check_fzf() -> None:
    if subprocess.run(["which", "fzf"], capture_output=True).returncode != 0:
        console.print("[red]Error:[/] fzf is not installed. See https://github.com/junegunn/fzf#installation")
        raise SystemExit(1)


# --- Rich prompt wrappers (replace gum) ------------------------------------

def prompt_input(placeholder: str, default: str = "") -> str:
    """Prompt for text input. Returns empty string on cancel."""
    try:
        return Prompt.ask(f"[dim]{placeholder}[/]", default=default, console=console)
    except (KeyboardInterrupt, EOFError):
        return ""


def prompt_confirm(message: str, default: bool = False) -> bool:
    """Prompt for yes/no confirmation."""
    try:
        return Confirm.ask(message, default=default, console=console)
    except (KeyboardInterrupt, EOFError):
        return False


def prompt_choose(header: str, *options: str) -> str | None:
    """Show numbered options and let user pick. Returns option text or None."""
    console.print(f"\n[dim]{header}[/]")
    for i, opt in enumerate(options, 1):
        console.print(f"  {i}  {opt}")
    console.print()
    try:
        choice = Prompt.ask("[dim]Choice[/]", console=console)
        idx = int(choice) - 1
        if 0 <= idx < len(options):
            return options[idx]
    except (ValueError, KeyboardInterrupt, EOFError):
        pass
    return None


# --- fzf wrappers ----------------------------------------------------------

def action_menu(header: str, *options: str) -> str | None:
    """Numbered fzf menu. Returns the option text or None."""
    check_fzf()
    lines = "\n".join(f"{i}  {opt}" for i, opt in enumerate(options, 1))
    result = subprocess.run(
        ["fzf", "--header", header, "--layout=reverse", "--height=~20",
         "--no-info", "--no-scrollbar", "--border", "--ansi", "--no-multi",
         "--prompt=› ", "--bind", "one:accept"],
        input=lines, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    import re
    return re.sub(r"^\d+\s+", "", result.stdout.strip())


def pick_todo(header: str = "Select a todo", prompt: str = "❯ ") -> str | None:
    """Show fzf picker of active todos. Returns selected todo ID or None."""
    check_fzf()
    lines = format_fzf_lines()
    if not lines:
        console.print("[yellow]No active todos.[/]")
        return None

    result = subprocess.run(
        ["fzf", "--header", header, "--layout=reverse", "--height=80%",
         "--with-nth=4..", "--no-hscroll", "--delimiter=\t", "--header-first",
         "--border", "--ansi", "--no-multi", f"--prompt={prompt}"],
        input=lines, capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return result.stdout.strip().split("\t")[0]


# --- Line formatting for fzf -----------------------------------------------

def format_fzf_lines(show_done: bool = True, group_filter: str = "") -> str:
    """Render todos as tab-delimited, ANSI-colored lines for fzf.

    Each line: ID\\tworktree\\tbranch\\t<visible columns>
    fzf uses --with-nth=4.. to display only the visible part.
    """
    all_todos = read_todos()

    # Filter by group
    if group_filter:
        all_todos = [t for t in all_todos
                     if t.get("group", "todo") == group_filter]
    if not show_done:
        all_todos = [t for t in all_todos if t.get("status") != "done"]

    if not all_todos:
        return ""

    # Build a parent→children map
    by_id = {t["id"]: t for t in all_todos}
    children: dict[str, list[dict]] = {}
    for t in all_todos:
        pid = t.get("parent_id", "")
        if pid:
            children.setdefault(pid, []).append(t)

    # Sort key
    def sort_key(t: dict) -> str:
        return t.get("last_opened_at") or t.get("created_at", "")

    # Walk up parent chain to find depth
    def depth(t: dict) -> int:
        d = 0
        cur = t
        while cur.get("parent_id") and cur["parent_id"] in by_id:
            d += 1
            cur = by_id[cur["parent_id"]]
        return d

    # Walk up to root ancestor
    def root_ancestor(t: dict) -> dict:
        cur = t
        while cur.get("parent_id") and cur["parent_id"] in by_id:
            cur = by_id[cur["parent_id"]]
        return cur

    # Emit tree: node, then active children, then done children
    def emit_tree(node: dict) -> list[dict]:
        result = [node]
        kids = children.get(node["id"], [])
        active_kids = sorted([k for k in kids if k.get("status") == "active"],
                             key=lambda t: t.get("created_at", ""))
        done_kids = sorted([k for k in kids if k.get("status") == "done"],
                           key=lambda t: t.get("created_at", ""))
        for kid in active_kids:
            result.extend(emit_tree(kid))
        for kid in done_kids:
            result.extend(emit_tree(kid))
        return result

    # Build ordered list
    roots_active = sorted(
        [t for t in all_todos if not t.get("parent_id") and t.get("status") == "active"],
        key=sort_key, reverse=True,
    )
    roots_done = sorted(
        [t for t in all_todos if not t.get("parent_id") and t.get("status") == "done"],
        key=sort_key, reverse=True,
    )

    ordered: list[dict] = []
    for r in roots_active:
        ordered.extend(emit_tree(r))
    for r in roots_done:
        ordered.extend(emit_tree(r))

    # Date boundaries
    now_ts = datetime.now(timezone.utc).timestamp()
    today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    yesterday_start = today_start - 86400

    lines: list[str] = []
    for t in ordered:
        tid = t["id"]
        title = t.get("title", "")
        status = t.get("status", "active")
        group = t.get("group", "todo")
        branch = t.get("branch", "")
        wt = t.get("worktree_path", "")
        ticket = t.get("linear_ticket", "")
        session = t.get("session_id", "")
        d = depth(t)
        is_subtask = d > 0

        # Dedup branch/dir vs root ancestor
        display_branch = branch
        display_wt = wt
        if is_subtask:
            root = root_ancestor(t)
            if branch == root.get("branch", ""):
                display_branch = ""
            if wt == root.get("worktree_path", ""):
                display_wt = ""

        # Age
        try:
            created_ts = datetime.strptime(t.get("created_at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
            if created_ts >= today_start:
                age = "today"
            elif created_ts >= yesterday_start:
                age = "yesterday"
            else:
                diff = now_ts - created_ts
                if diff < 604800:
                    age = f"{int(diff / 86400)}d ago"
                else:
                    age = t.get("created_at", "")[:10]
        except (ValueError, TypeError):
            age = ""

        # Dir from worktree path
        dir_name = display_wt.rsplit("/", 1)[-1] if display_wt else ""

        # Indent
        indent = ("   " * (d - 1) + "└─ ") if is_subtask else ""
        tw = max(80 - d * 3, 0)

        # Build columns
        age_col = f"{age:<10}"
        full_title = f"{ticket} {title}" if ticket else title
        title_col = f"{full_title[:tw]:<{tw}}"
        dir_col = f"{dir_name[:16]:<16}"
        branch_col = f"{display_branch[:30]:<30}"

        DIM = "\033[2m"
        RST = "\033[0m"
        GREEN = "\033[0;32m"
        CYAN = "\033[0;36m"
        MAGENTA = "\033[0;35m"
        STRIKE = "\033[2;9m"

        if status == "done":
            visible = f"{STRIKE}{age_col}  {RST}{GREEN}✓{STRIKE} {indent}{title_col}  {dir_col}  {branch_col}{RST}"
        else:
            if group == "backlog":
                icon = f"{DIM}○{RST} " if session else "  "
            else:
                icon = f"{GREEN}◉{RST} " if session else "  "

            if ticket:
                ttw = tw - len(ticket) - 1
                colored_title = f"{MAGENTA}{ticket}{RST} {title[:ttw]:<{max(ttw, 0)}}"
            else:
                colored_title = title_col

            visible = f"{DIM}{age_col}{RST}  {icon}{indent}{colored_title}  {DIM}{dir_col}{RST}  {CYAN}{branch_col}{RST}"

        lines.append(f"{tid}\t{wt}\t{branch}\t{visible}")

    return "\n".join(lines)
