"""Integration tests for td CLI commands — validates Python td matches bash behavior."""

import json
import os
import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def td(isolated_env):
    """Run the Python td CLI via subprocess."""
    env = os.environ.copy()
    env["TODO_DATA_DIR"] = str(isolated_env["data_dir"])
    env["TODO_REPO"] = str(isolated_env["repo_dir"])
    env["TODO_EDITOR"] = "true"
    env["TODO_SETTINGS"] = str(isolated_env["tmp_path"] / "settings.json")
    # Use the venv's td binary
    td_bin = str(Path(__file__).resolve().parent.parent / ".venv" / "bin" / "td")

    def run(*args, quiet=False):
        cmd_env = env.copy()
        if quiet:
            cmd_env["TODO_QUIET"] = "1"
        result = subprocess.run(
            [td_bin, *args],
            capture_output=True, text=True, env=cmd_env,
        )
        return result

    return run


def todos_json(isolated_env):
    return json.loads((isolated_env["data_dir"] / "todos.json").read_text())


class TestVersion:
    def test_prints_version(self, td):
        r = td("version")
        assert r.returncode == 0
        assert r.stdout.strip().startswith("td ")


class TestHelp:
    def test_shows_help(self, td):
        r = td("help")
        assert "Minimal task manager" in r.stdout
        assert "Non-interactive" in r.stdout


class TestNew:
    def test_creates_todo(self, td, isolated_env):
        r = td("new", "Test todo item")
        assert r.returncode == 0
        assert "Created" in r.stderr
        assert "Test todo item" in r.stderr

        todos = todos_json(isolated_env)
        assert len(todos) == 1
        assert todos[0]["title"] == "Test todo item"
        assert todos[0]["status"] == "active"
        assert todos[0]["group"] == "todo"
        assert Path(todos[0]["notes_path"]).exists()

    def test_backlog(self, td, isolated_env):
        td("new", "-b", "Backlog item")
        todos = todos_json(isolated_env)
        assert todos[0]["group"] == "backlog"

    def test_quiet_mode(self, td, isolated_env):
        r = td("new", "Quiet item", quiet=True)
        assert "Created" not in r.stdout
        assert "quiet-item" in r.stdout.strip()


class TestGet:
    def test_returns_json(self, td, isolated_env):
        td("new", "Get test")
        todo_id = todos_json(isolated_env)[0]["id"]
        r = td("get", todo_id)
        data = json.loads(r.stdout)
        assert data["title"] == "Get test"
        assert data["id"] == todo_id

    def test_prefix_resolution(self, td, isolated_env):
        td("new", "Prefix test")
        r = td("get", "prefix-tes")
        data = json.loads(r.stdout)
        assert data["title"] == "Prefix test"

    def test_no_id_error(self, td):
        r = td("get")
        assert r.returncode != 0

    def test_bad_id_error(self, td):
        r = td("get", "nonexistent-id-xyz")
        assert r.returncode != 0


class TestNote:
    def test_appends_note(self, td, isolated_env):
        td("new", "Note test")
        todo_id = todos_json(isolated_env)[0]["id"]
        notes_path = todos_json(isolated_env)[0]["notes_path"]

        td("note", todo_id, "Appended note text")
        content = Path(notes_path).read_text()
        assert "Appended note text" in content


class TestShow:
    def test_prints_path(self, td, isolated_env):
        td("new", "Show test")
        todo_id = todos_json(isolated_env)[0]["id"]
        r = td("show", todo_id)
        assert "plan.md" in r.stdout
        assert Path(r.stdout.strip()).exists()


class TestList:
    def test_shows_todos(self, td, isolated_env):
        td("new", "List A")
        td("new", "List B")
        r = td("list")
        assert "List A" in r.stderr
        assert "List B" in r.stderr
        assert "TODO" in r.stderr

    def test_json_mode(self, td, isolated_env):
        td("new", "Json test")
        r = td("list", "--json")
        data = json.loads(r.stdout)
        assert isinstance(data, list)
        assert len(data) == 1

    def test_backlog_section(self, td, isolated_env):
        td("new", "-b", "Backlog item")
        r = td("list")
        assert "Backlog" in r.stderr


class TestDone:
    def test_marks_done(self, td, isolated_env):
        td("new", "Done test")
        todo_id = todos_json(isolated_env)[0]["id"]
        r = td("done", todo_id)
        assert "Done" in r.stderr
        assert todos_json(isolated_env)[0]["status"] == "done"

    def test_cascades_to_subtasks(self, td, isolated_env):
        td("new", "Parent done")
        pid = todos_json(isolated_env)[0]["id"]
        td("split", pid, "Child done")
        cid = todos_json(isolated_env)[-1]["id"]

        td("done", pid)
        todos = {t["id"]: t for t in todos_json(isolated_env)}
        assert todos[pid]["status"] == "done"
        assert todos[cid]["status"] == "done"


class TestArchive:
    def test_shows_completed(self, td, isolated_env):
        td("new", "Archive test")
        todo_id = todos_json(isolated_env)[0]["id"]
        td("done", todo_id)
        r = td("archive")
        assert "Archive test" in r.stderr
        assert "Completed" in r.stderr


class TestSplit:
    def test_creates_subtask(self, td, isolated_env):
        td("new", "Parent")
        pid = todos_json(isolated_env)[0]["id"]
        td("link", pid, "https://github.com/Maybern/maybern/tree/feature/parent")

        r = td("split", pid, "Child")
        assert "Created subtask" in r.stderr
        assert "Parent" in r.stderr

        todos = todos_json(isolated_env)
        child = todos[-1]
        assert child["parent_id"] == pid
        assert child["branch"] == "feature/parent"

    def test_notes_nested_under_parent(self, td, isolated_env):
        td("new", "Nest parent")
        pid = todos_json(isolated_env)[0]["id"]
        parent_notes = todos_json(isolated_env)[0]["notes_path"]
        parent_dir = str(Path(parent_notes).parent)

        td("split", pid, "Nest child")
        child_notes = todos_json(isolated_env)[-1]["notes_path"]
        assert parent_dir in child_notes


class TestLink:
    def test_linear_url(self, td, isolated_env):
        td("new", "Link linear")
        tid = todos_json(isolated_env)[0]["id"]
        r = td("link", tid, "https://linear.app/maybern/issue/core-12207/some-title")
        assert "Linked" in r.stderr
        assert "CORE-12207" in r.stderr
        assert todos_json(isolated_env)[0]["linear_ticket"] == "CORE-12207"

    def test_github_branch_url(self, td, isolated_env):
        td("new", "Link branch")
        tid = todos_json(isolated_env)[0]["id"]
        td("link", tid, "https://github.com/Maybern/maybern/tree/fix/some-bug")
        assert todos_json(isolated_env)[0]["branch"] == "fix/some-bug"

    def test_github_pr_url(self, td, isolated_env):
        td("new", "Link PR")
        tid = todos_json(isolated_env)[0]["id"]
        pr = "https://github.com/Maybern/maybern/pull/15530"
        td("link", tid, pr)
        assert todos_json(isolated_env)[0]["github_pr"] == pr

    def test_file_path(self, td, isolated_env):
        td("new", "Link file")
        tid = todos_json(isolated_env)[0]["id"]
        fpath = str(isolated_env["tmp_path"] / "my-plan.md")
        Path(fpath).write_text("# Plan")
        td("link", tid, fpath)
        assert "my-plan.md" in todos_json(isolated_env)[0]["notes_path"]


class TestBump:
    def test_toggles_group(self, td, isolated_env):
        td("new", "Bump test")
        tid = todos_json(isolated_env)[0]["id"]
        assert todos_json(isolated_env)[0].get("group", "todo") == "todo"

        td("bump", tid)
        assert todos_json(isolated_env)[0]["group"] == "backlog"

        td("bump", tid)
        assert todos_json(isolated_env)[0]["group"] == "todo"

    def test_cascades_to_subtasks(self, td, isolated_env):
        td("new", "Bump parent")
        pid = todos_json(isolated_env)[0]["id"]
        td("split", pid, "Bump child")
        cid = todos_json(isolated_env)[-1]["id"]

        td("bump", pid)
        todos = {t["id"]: t for t in todos_json(isolated_env)}
        assert todos[pid]["group"] == "backlog"
        assert todos[cid]["group"] == "backlog"


class TestRename:
    def test_renames(self, td, isolated_env):
        td("new", "Old name")
        tid = todos_json(isolated_env)[0]["id"]
        old_notes = todos_json(isolated_env)[0]["notes_path"]

        r = td("rename", tid, "New name")
        assert "Old name" in r.stderr
        assert "New name" in r.stderr

        t = todos_json(isolated_env)[0]
        assert t["title"] == "New name"
        assert "New name" in t["notes_path"]
        assert Path(t["notes_path"]).parent.exists()
        assert not Path(old_notes).parent.exists()


class TestDelete:
    def test_force_delete(self, td, isolated_env):
        td("new", "Delete me")
        tid = todos_json(isolated_env)[0]["id"]
        notes_dir = Path(todos_json(isolated_env)[0]["notes_path"]).parent

        r = td("delete", tid, "--force")
        assert "Deleted" in r.stderr
        assert len(todos_json(isolated_env)) == 0
        assert not notes_dir.exists()

    def test_cascades_to_subtasks(self, td, isolated_env):
        td("new", "Del parent")
        pid = todos_json(isolated_env)[0]["id"]
        td("split", pid, "Del child")

        td("delete", pid, "--force")
        assert len(todos_json(isolated_env)) == 0


class TestEdit:
    def test_runs_without_error(self, td, isolated_env):
        td("new", "Edit test")
        tid = todos_json(isolated_env)[0]["id"]
        r = td("edit", tid)
        assert r.returncode == 0


class TestBrowse:
    def test_runs_without_error(self, td):
        r = td("browse")
        assert r.returncode == 0


class TestSettings:
    def test_no_file(self, td):
        r = td("settings")
        assert r.returncode == 1
        assert "No settings file" in r.stderr

    def test_with_file(self, td, isolated_env):
        settings_path = isolated_env["tmp_path"] / "settings.json"
        settings_path.write_text('{"data_dir": "~/td", "editor": "code"}')
        r = td("settings")
        assert r.returncode == 0
        assert "data_dir" in r.stdout


class TestSync:
    def test_creates_from_orphaned_dirs(self, td, isolated_env):
        orphan = isolated_env["data_dir"] / "todo" / "Orphan task"
        orphan.mkdir(parents=True)
        (orphan / "plan.md").write_text("# Orphan task\n")

        r = td("sync")
        assert "Created todo" in r.stderr
        titles = [t["title"] for t in todos_json(isolated_env)]
        assert "Orphan task" in titles

    def test_dry_run(self, td, isolated_env):
        orphan = isolated_env["data_dir"] / "todo" / "Dry run task"
        orphan.mkdir(parents=True)
        (orphan / "plan.md").write_text("# Dry run task\n")

        r = td("sync", "-n")
        assert "Would create" in r.stderr
        assert "Dry run" in r.stderr
        assert len(todos_json(isolated_env)) == 0

    def test_removes_orphaned_todos(self, td, isolated_env):
        td("new", "Will orphan")
        notes_dir = Path(todos_json(isolated_env)[0]["notes_path"]).parent
        import shutil
        shutil.rmtree(notes_dir)

        r = td("sync")
        assert "Removed orphaned" in r.stderr
        assert len(todos_json(isolated_env)) == 0


class TestIdCollision:
    def test_duplicate_titles(self, td, isolated_env):
        td("new", "Same title")
        td("new", "Same title")
        todos = todos_json(isolated_env)
        assert todos[0]["id"] != todos[1]["id"]
        assert todos[1]["id"] == "same-title-2"


class TestUnknownCommand:
    def test_error(self, td):
        r = td("bogus")
        assert r.returncode != 0


class TestWorktree:
    def test_create_worktree(self, td, isolated_env):
        """Test _init_worktree_for_todo via sourcing — same as bash test."""
        td("new", "Worktree test")
        tid = todos_json(isolated_env)[0]["id"]
        repo = str(isolated_env["repo_dir"])

        # Link branch
        td("link", tid, "https://github.com/Maybern/maybern/tree/todo/wt-test")
        # Create local branch
        subprocess.run(["git", "-C", repo, "branch", "todo/wt-test"], check=True)

        # Call init_worktree_for_todo via Python
        env = os.environ.copy()
        env["TODO_DATA_DIR"] = str(isolated_env["data_dir"])
        env["TODO_REPO"] = repo
        env["TODO_EDITOR"] = "true"
        env["TODO_SETTINGS"] = str(isolated_env["tmp_path"] / "settings.json")

        subprocess.run([
            str(Path(__file__).resolve().parent.parent / ".venv" / "bin" / "python"), "-c",
            f"""
import importlib, os
os.environ["TODO_DATA_DIR"] = "{isolated_env['data_dir']}"
os.environ["TODO_REPO"] = "{repo}"
os.environ["TODO_EDITOR"] = "true"
os.environ["TODO_SETTINGS"] = "{isolated_env['tmp_path'] / 'settings.json'}"
import td_cli.config; importlib.reload(td_cli.config)
import td_cli.data; importlib.reload(td_cli.data)
from td_cli.session import init_worktree_for_todo
init_worktree_for_todo("{tid}")
""",
        ], check=True, env=env, capture_output=True)

        t = todos_json(isolated_env)[0]
        assert t["worktree_path"]
        assert t["branch"] == "todo/wt-test"
        assert Path(t["worktree_path"]).is_dir()


class TestTry:
    def test_no_worktree_error(self, td, isolated_env):
        td("new", "Try no wt")
        tid = todos_json(isolated_env)[0]["id"]
        r = td("try", tid)
        assert r.returncode == 1
        assert "no worktree" in r.stderr
