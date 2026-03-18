"""Tests for td_cli.data — JSON CRUD, ID generation, notes."""

import json
from pathlib import Path

import pytest

from td_cli.data import (
    active_todos,
    done_todos,
    ensure_notes,
    ensure_setup,
    generate_id,
    get_todo,
    notes_folder_name,
    now_iso,
    read_todos,
    resolve_id,
    slugify,
    write_todos,
)


class TestSlugify:
    def test_basic(self):
        assert slugify("Fix Document Audit") == "fix-document-audit"

    def test_special_chars(self):
        assert slugify("hello world! @#$%") == "hello-world"

    def test_collapses_dashes(self):
        assert slugify("a---b") == "a-b"

    def test_truncates_to_40(self):
        long = "a" * 60
        assert len(slugify(long)) == 40

    def test_empty_string(self):
        assert slugify("") == ""

    def test_strips_leading_trailing_dashes(self):
        assert slugify("--hello--") == "hello"


class TestGenerateId:
    def test_basic(self):
        assert generate_id("My New Task") == "my-new-task"

    def test_collision(self):
        write_todos([{"id": "my-task", "title": "My Task", "status": "active"}])
        assert generate_id("My Task") == "my-task-2"

    def test_double_collision(self):
        write_todos([
            {"id": "my-task", "title": "My Task", "status": "active"},
            {"id": "my-task-2", "title": "My Task", "status": "active"},
        ])
        assert generate_id("My Task") == "my-task-3"

    def test_empty_title(self):
        assert generate_id("") == "untitled"


class TestNotesFolderName:
    def test_basic(self, isolated_env):
        name = notes_folder_name("test-id", "My Task")
        assert name == "My Task"

    def test_strips_unsafe_chars(self, isolated_env):
        name = notes_folder_name("test-id", 'File: "bad/name"')
        assert "/" not in name
        assert '"' not in name

    def test_collision(self, isolated_env):
        base = Path(isolated_env["data_dir"]) / "todo"
        (base / "Same Name").mkdir()
        (base / "Same Name" / "plan.md").write_text("# Same Name")
        # Write a todo that owns this folder
        write_todos([{"id": "other-id", "title": "Same Name", "status": "active",
                       "notes_path": str(base / "Same Name" / "plan.md")}])
        name = notes_folder_name("new-id", "Same Name")
        assert name == "Same Name 2"

    def test_same_id_reuses_folder(self, isolated_env):
        base = Path(isolated_env["data_dir"]) / "todo"
        (base / "Task").mkdir()
        (base / "Task" / "plan.md").write_text("# Task")
        write_todos([{"id": "my-id", "title": "Task", "status": "active",
                       "notes_path": str(base / "Task" / "plan.md")}])
        name = notes_folder_name("my-id", "Task")
        assert name == "Task"


class TestReadWriteTodos:
    def test_roundtrip(self):
        todos = [{"id": "test", "title": "Test", "status": "active"}]
        write_todos(todos)
        assert read_todos() == todos

    def test_empty_file(self):
        write_todos([])
        assert read_todos() == []


class TestGetTodo:
    def test_found(self):
        write_todos([{"id": "abc", "title": "ABC", "status": "active"}])
        t = get_todo("abc")
        assert t is not None
        assert t["title"] == "ABC"

    def test_not_found(self):
        write_todos([{"id": "abc", "title": "ABC", "status": "active"}])
        assert get_todo("xyz") is None


class TestActiveDoneTodos:
    def test_active(self):
        write_todos([
            {"id": "a", "title": "A", "status": "active", "created_at": "2026-01-01T00:00:00Z"},
            {"id": "b", "title": "B", "status": "done", "created_at": "2026-01-02T00:00:00Z"},
            {"id": "c", "title": "C", "status": "active", "created_at": "2026-01-03T00:00:00Z"},
        ])
        result = active_todos()
        assert len(result) == 2
        assert result[0]["id"] == "c"  # most recent first

    def test_done(self):
        write_todos([
            {"id": "a", "title": "A", "status": "active", "created_at": "2026-01-01T00:00:00Z"},
            {"id": "b", "title": "B", "status": "done", "created_at": "2026-01-02T00:00:00Z"},
        ])
        result = done_todos()
        assert len(result) == 1
        assert result[0]["id"] == "b"


class TestResolveId:
    def test_exact(self):
        write_todos([{"id": "fix-bug", "title": "Fix Bug", "status": "active"}])
        assert resolve_id("fix-bug") == "fix-bug"

    def test_prefix(self):
        write_todos([{"id": "fix-document-audit", "title": "Fix", "status": "active"}])
        assert resolve_id("fix-doc") == "fix-document-audit"

    def test_suffix(self):
        write_todos([{"id": "fix-document-audit", "title": "Fix", "status": "active"}])
        assert resolve_id("ment-audit") == "fix-document-audit"

    def test_ambiguous_prefix(self):
        import click
        write_todos([
            {"id": "fix-a", "title": "A", "status": "active"},
            {"id": "fix-b", "title": "B", "status": "active"},
        ])
        with pytest.raises((SystemExit, click.exceptions.BadParameter)):
            resolve_id("fix-")

    def test_no_match(self):
        import click
        write_todos([{"id": "abc", "title": "ABC", "status": "active"}])
        with pytest.raises((SystemExit, click.exceptions.BadParameter)):
            resolve_id("xyz")

    def test_empty(self):
        import click
        with pytest.raises((SystemExit, click.exceptions.BadParameter)):
            resolve_id("")


class TestEnsureNotes:
    def test_creates_plan(self):
        write_todos([{"id": "test", "title": "Test Task", "status": "active"}])
        path = ensure_notes("test", "Test Task")
        assert Path(path).exists()
        content = Path(path).read_text()
        assert "# Test Task" in content
        assert "## Plan" in content

    def test_subtask_nested_under_parent(self, isolated_env):
        base = Path(isolated_env["data_dir"]) / "todo"
        parent_dir = base / "Parent Task"
        parent_dir.mkdir()
        parent_plan = parent_dir / "plan.md"
        parent_plan.write_text("# Parent Task\n")
        write_todos([
            {"id": "parent", "title": "Parent Task", "status": "active",
             "notes_path": str(parent_plan)},
            {"id": "child", "title": "Child Task", "status": "active",
             "parent_id": "parent"},
        ])
        path = ensure_notes("child", "Child Task")
        assert str(parent_dir) in path


class TestNowIso:
    def test_format(self):
        ts = now_iso()
        assert ts.endswith("Z")
        assert "T" in ts


class TestEnsureSetup:
    def test_creates_dirs(self, isolated_env):
        # Remove what was created by fixture
        import shutil
        data_dir = Path(isolated_env["data_dir"])
        shutil.rmtree(data_dir)
        ensure_setup()
        assert data_dir.exists()
        assert (data_dir / "todos.json").exists()
        assert (data_dir / "todo").is_dir()
