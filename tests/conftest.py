"""Shared test fixtures."""

import json
import os
import subprocess
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def isolated_env(tmp_path, monkeypatch):
    """Set up isolated data dir and git repo for every test."""
    data_dir = tmp_path / "data"
    repo_dir = tmp_path / "repo"

    data_dir.mkdir()
    (data_dir / "todo").mkdir()
    (data_dir / "done").mkdir()
    (data_dir / "todos.json").write_text("[]")

    repo_dir.mkdir()
    subprocess.run(["git", "init", "-q", str(repo_dir)], check=True)
    subprocess.run(
        ["git", "-C", str(repo_dir), "commit", "--allow-empty", "-m", "init", "-q"],
        check=True,
    )

    monkeypatch.setenv("TODO_DATA_DIR", str(data_dir))
    monkeypatch.setenv("TODO_REPO", str(repo_dir))
    monkeypatch.setenv("TODO_EDITOR", "true")
    monkeypatch.setenv("TODO_SETTINGS", str(tmp_path / "settings.json"))

    # Force reload of config module with new env vars
    import importlib
    import td_cli.config
    importlib.reload(td_cli.config)
    import td_cli.data
    importlib.reload(td_cli.data)

    yield {
        "data_dir": data_dir,
        "repo_dir": repo_dir,
        "tmp_path": tmp_path,
    }
