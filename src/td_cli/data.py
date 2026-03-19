"""JSON data access and todo CRUD helpers."""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from td_cli.config import DATA_DIR, DONE_DIR, NOTES_DIR, TODOS_FILE, console

# --- Random names -----------------------------------------------------------

_NYC_NAMES = [
    "gowanus", "fort greene", "red hook", "dumbo", "tribeca", "nolita", "soho",
    "chinatown", "bed-stuy", "bushwick", "williamsburg", "greenpoint", "astoria",
    "flushing", "jackson heights", "long island city", "rockaway beach",
    "coney island", "brighton beach", "bay ridge", "sunset park", "park slope",
    "crown heights", "flatbush", "cobble hill", "boerum hill", "carroll gardens",
    "clinton hill", "vinegar hill", "east village", "west village",
    "lower east side", "gramercy", "kips bay", "murray hill", "hells kitchen",
    "harlem", "washington heights", "inwood", "chelsea", "flatiron", "noho",
    "two bridges", "alphabet city", "el barrio", "marble hill",
    "spuyten duyvil", "sunnyside", "woodside", "corona", "forest hills",
    "jamaica", "st george", "canal & broadway", "broadway & 42nd", "5th & 23rd",
    "delancey & essex", "atlantic & flatbush", "bedford & grand",
    "houston & bowery", "bleecker & macdougal", "st marks place", "astor place",
    "union square", "times square", "herald square", "madison square",
    "washington square", "tompkins square", "grand army plaza",
    "columbus circle", "brooklyn bridge", "manhattan bridge",
    "williamsburg bridge", "verrazzano", "george washington bridge",
    "statue of liberty", "ellis island", "governors island",
    "roosevelt island", "rikers island", "central park", "prospect park",
    "highline", "bryant park", "battery park", "riverside park", "fort tryon",
    "pelham bay", "the cloisters", "lincoln center", "carnegie hall",
    "radio city", "grand central", "penn station", "fulton street",
    "wall street", "rockefeller center", "empire state", "chrysler building",
    "flatiron building", "woolworth building", "one world trade", "met museum",
    "guggenheim", "moma", "apollo theater", "yankee stadium", "citi field",
    "barclays center", "madison square garden", "oculus", "domino park",
    "jane's carousel", "little island", "vessel", "bethesda fountain",
    "strawberry fields", "bow bridge", "belvedere castle", "the ramble",
    "sheep meadow", "the reservoir",
]


def random_name() -> str:
    import random
    return random.choice(_NYC_NAMES)


# --- Setup ------------------------------------------------------------------

def ensure_setup() -> None:
    """Create data directory and todos.json if they don't exist."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    # Migrate notes/ → todo/ (one-time)
    old_notes = DATA_DIR / "notes"
    if old_notes.is_dir() and not NOTES_DIR.is_dir():
        old_notes.rename(NOTES_DIR)
        if TODOS_FILE.exists():
            todos = read_todos()
            for t in todos:
                if t.get("notes_path"):
                    t["notes_path"] = t["notes_path"].replace("/notes/", "/todo/")
            write_todos(todos)
    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    DONE_DIR.mkdir(parents=True, exist_ok=True)
    if not TODOS_FILE.exists():
        TODOS_FILE.write_text("[]")


# --- ID helpers -------------------------------------------------------------

def slugify(text: str) -> str:
    """Lowercase, strip non-alphanumeric, collapse dashes, truncate to 40."""
    s = text.lower()
    s = re.sub(r"[^a-z0-9]", "-", s)
    s = re.sub(r"-+", "-", s)
    s = s.strip("-")
    return s[:40]


def generate_id(title: str) -> str:
    """Produce a slug ID from the title, handling collisions."""
    slug = slugify(title) or "untitled"
    todos = read_todos()
    existing_ids = {t["id"] for t in todos}
    candidate = slug
    n = 2
    while candidate in existing_ids:
        candidate = f"{slug}-{n}"
        n += 1
    return candidate


def notes_folder_name(todo_id: str, title: str, base_dir: Path | None = None) -> str:
    """Return a folder name for the todo's notes. Handles collisions."""
    if base_dir is None:
        base_dir = NOTES_DIR
    # Strip filesystem-unsafe characters
    name = re.sub(r'[/\\:*?"<>|]', "", title)
    name = name.strip(" .")
    if not name:
        name = "untitled"
    candidate = name
    n = 2
    while (base_dir / candidate).is_dir():
        # Check if this folder belongs to the same todo
        plan = base_dir / candidate / "plan.md"
        if plan.exists():
            todos = read_todos()
            owner = next((t for t in todos if t.get("notes_path") == str(plan)), None)
            if owner and owner["id"] == todo_id:
                break
        candidate = f"{name} {n}"
        n += 1
    return candidate


# --- Read/write -------------------------------------------------------------

def read_todos() -> list[dict]:
    """Read the todos JSON array."""
    try:
        return json.loads(TODOS_FILE.read_text())
    except (json.JSONDecodeError, FileNotFoundError):
        return []


def write_todos(todos: list[dict]) -> None:
    """Write the todos JSON array."""
    TODOS_FILE.write_text(json.dumps(todos, indent=2) + "\n")


# --- Queries ----------------------------------------------------------------

def get_todo(todo_id: str) -> dict | None:
    """Return a single todo by ID, or None."""
    return next((t for t in read_todos() if t["id"] == todo_id), None)


def active_todos() -> list[dict]:
    """Return active todos sorted by created_at descending."""
    todos = [t for t in read_todos() if t.get("status") == "active"]
    todos.sort(key=lambda t: t.get("created_at", ""), reverse=True)
    return todos


def done_todos() -> list[dict]:
    """Return done todos sorted by created_at descending."""
    todos = [t for t in read_todos() if t.get("status") == "done"]
    todos.sort(key=lambda t: t.get("created_at", ""), reverse=True)
    return todos


# --- ID resolution ----------------------------------------------------------

def resolve_id(input_id: str) -> str:
    """Resolve exact/prefix/suffix match. Returns full ID or raises SystemExit."""
    if not input_id:
        import typer
        raise typer.BadParameter("No ID provided.")

    todos = read_todos()

    # Exact match
    exact = next((t for t in todos if t["id"] == input_id), None)
    if exact:
        return exact["id"]

    # Prefix match (must be unique)
    prefix_matches = [t for t in todos if t["id"].startswith(input_id)]
    if len(prefix_matches) == 1:
        return prefix_matches[0]["id"]

    # Suffix match (must be unique)
    suffix_matches = [t for t in todos if t["id"].endswith(input_id)]
    if len(suffix_matches) == 1:
        return suffix_matches[0]["id"]

    import typer
    raise typer.BadParameter(f"No unique todo found for '{input_id}'")


# --- Notes ------------------------------------------------------------------

def ensure_notes(todo_id: str, title: str) -> str:
    """Create plan.md for a todo if it doesn't exist. Returns the file path."""
    todos = read_todos()
    todo = next((t for t in todos if t["id"] == todo_id), None)
    if not todo:
        return ""

    base_dir = DONE_DIR if todo.get("status") == "done" else NOTES_DIR
    parent_id = todo.get("parent_id", "")
    if parent_id:
        parent = next((t for t in todos if t["id"] == parent_id), None)
        if parent and parent.get("notes_path"):
            base_dir = Path(parent["notes_path"]).parent

    folder = notes_folder_name(todo_id, title, base_dir)
    notes_path = base_dir / folder

    plan_file = notes_path / "plan.md"
    if not plan_file.exists():
        notes_path.mkdir(parents=True, exist_ok=True)
        now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
        plan_file.write_text(f"# {title}\n\nCreated: {now_str}\n\n## Plan\n\n")
        # Persist notes_path
        todos = read_todos()
        for t in todos:
            if t["id"] == todo_id:
                t["notes_path"] = str(plan_file)
        write_todos(todos)

    return str(plan_file)


# --- Timestamps -------------------------------------------------------------

def now_iso() -> str:
    """Return current UTC time in ISO format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
