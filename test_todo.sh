#!/usr/bin/env bash
set -euo pipefail

# Functional tests for the todo CLI.
# Tests all user-facing commands and tool interactions.
# Skips interactive flows (fzf picker, gum prompts) and Claude-specific logic.

TODO_BIN="$(cd "$(dirname "$0")" && pwd)/td"

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR=$(mktemp -d)
    export TODO_DATA_DIR="${TEST_DIR}/data"
    export TODO_REPO="${TEST_DIR}/repo"
    export TODO_EDITOR="true"  # no-op editor

    # Create a git repo
    git init -q "$TODO_REPO"
    git -C "$TODO_REPO" commit --allow-empty -m "init" -q
}

teardown() {
    rm -rf "$TEST_DIR"
}

todo() {
    "$TODO_BIN" "$@"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}expected: ${expected}${RESET}"
        echo -e "    ${DIM}actual:   ${actual}${RESET}"
    fi
}

assert_contains() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" == *"$expected"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}expected to contain: ${expected}${RESET}"
        echo -e "    ${DIM}actual: ${actual}${RESET}"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -f "$path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}file not found: ${path}${RESET}"
    fi
}

assert_not_empty() {
    local label="$1" value="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -n "$value" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}value was empty${RESET}"
    fi
}

assert_not_contains() {
    local label="$1" unexpected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" != *"$unexpected"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}should not contain: ${unexpected}${RESET}"
        echo -e "    ${DIM}actual: ${actual}${RESET}"
    fi
}

assert_exit_code() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}expected exit code: ${expected}${RESET}"
        echo -e "    ${DIM}actual exit code:   ${actual}${RESET}"
    fi
}

assert_dir_exists() {
    local label="$1" path="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -d "$path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}directory not found: ${path}${RESET}"
    fi
}

assert_dir_not_exists() {
    local label="$1" path="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ ! -d "$path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} ${label}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} ${label}"
        echo -e "    ${DIM}directory should not exist: ${path}${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_help() {
    echo -e "${BOLD}test: help${RESET}"
    local output
    output=$(todo help)
    assert_contains "shows description" "Minimal task manager" "$output"
    assert_contains "shows commands" "td new" "$output"
    assert_contains "shows environment" "Config" "$output"
}

test_new() {
    echo -e "${BOLD}test: new${RESET}"
    local output
    output=$(todo new "Test todo item")
    assert_contains "prints confirmation" "Created" "$output"
    assert_contains "prints title" "Test todo item" "$output"

    # Check JSON
    local count
    count=$(jq 'length' < "$TODO_DATA_DIR/todos.json")
    assert_eq "todo added to JSON" "1" "$count"

    local title
    title=$(jq -r '.[0].title' < "$TODO_DATA_DIR/todos.json")
    assert_eq "title stored correctly" "Test todo item" "$title"

    local status
    status=$(jq -r '.[0].status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "status is active" "active" "$status"

    # Check notes file
    local notes_path
    notes_path=$(jq -r '.[0].notes_path' < "$TODO_DATA_DIR/todos.json")
    assert_file_exists "notes.md created" "$notes_path"

    local notes_content
    notes_content=$(cat "$notes_path")
    assert_contains "notes has title" "Test todo item" "$notes_content"
}

test_get() {
    echo -e "${BOLD}test: get${RESET}"
    todo new "Get test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo get "$id")
    assert_contains "returns JSON with title" "Get test" "$output"
    assert_contains "returns JSON with id" "$id" "$output"
}

test_note() {
    echo -e "${BOLD}test: note${RESET}"
    todo new "Note test" >/dev/null
    local id notes_path
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")
    notes_path=$(jq -r '.[-1].notes_path' < "$TODO_DATA_DIR/todos.json")

    todo note "$id" "This is an appended note"
    local content
    content=$(cat "$notes_path")
    assert_contains "note appended to file" "This is an appended note" "$content"
}

test_show() {
    echo -e "${BOLD}test: show${RESET}"
    todo new "Show test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo show "$id")
    assert_contains "prints notes path" "plan.md" "$output"
    assert_file_exists "path exists" "$output"
}

test_list() {
    echo -e "${BOLD}test: list${RESET}"
    todo new "List item A" >/dev/null
    todo new "List item B" >/dev/null

    local output
    output=$(todo list)
    assert_contains "shows item A" "List item A" "$output"
    assert_contains "shows item B" "List item B" "$output"
    assert_contains "shows header" "TODO" "$output"
}

test_done() {
    echo -e "${BOLD}test: done${RESET}"
    todo new "Done test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo done "$id")
    assert_contains "prints confirmation" "Done" "$output"

    local status
    status=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "status changed to done" "done" "$status"
}

test_archive() {
    echo -e "${BOLD}test: archive${RESET}"
    todo new "Archive test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")
    todo done "$id" >/dev/null

    local output
    output=$(todo archive)
    assert_contains "shows completed item" "Archive test" "$output"
    assert_contains "shows header" "Completed" "$output"
}

test_link_linear() {
    echo -e "${BOLD}test: link linear URL${RESET}"
    todo new "Link linear test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo link "$id" "https://linear.app/maybern/issue/core-12207/some-title")
    assert_contains "prints confirmation" "Linked" "$output"
    assert_contains "shows ticket ID" "CORE-12207" "$output"

    local ticket
    ticket=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .linear_ticket' < "$TODO_DATA_DIR/todos.json")
    assert_eq "ticket stored" "CORE-12207" "$ticket"
}

test_link_github_branch() {
    echo -e "${BOLD}test: link github branch URL${RESET}"
    todo new "Link github test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo link "$id" "https://github.com/Maybern/maybern/tree/fix/some-bug")
    assert_contains "prints confirmation" "Linked" "$output"

    local branch
    branch=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .branch' < "$TODO_DATA_DIR/todos.json")
    assert_eq "branch extracted from URL" "fix/some-bug" "$branch"
}

test_split() {
    echo -e "${BOLD}test: split${RESET}"
    todo new "Parent task" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Link branch to parent so subtask inherits it
    todo link "$parent_id" "https://github.com/Maybern/maybern/tree/feature/parent" >/dev/null

    local output
    output=$(todo split "$parent_id" "Child subtask")
    assert_contains "prints confirmation" "Created subtask" "$output"
    assert_contains "shows parent" "Parent task" "$output"

    local child_id
    child_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local child_parent
    child_parent=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .parent_id' < "$TODO_DATA_DIR/todos.json")
    assert_eq "parent_id set" "$parent_id" "$child_parent"

    local child_branch
    child_branch=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .branch' < "$TODO_DATA_DIR/todos.json")
    assert_eq "branch inherited from parent" "feature/parent" "$child_branch"
}

test_edit() {
    echo -e "${BOLD}test: edit${RESET}"
    todo new "Edit test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # TODO_EDITOR=true means it runs `true <path>` which is a no-op success
    todo edit "$id"
    # If we get here without error, the command works
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${RESET} edit runs without error"
}

test_resolve_id_prefix() {
    echo -e "${BOLD}test: ID prefix resolution${RESET}"
    todo new "Prefix test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Use full ID minus last char — unique enough
    local prefix="${id:0:${#id}-1}"
    local output
    output=$(todo get "$prefix")
    assert_contains "resolves by prefix" "Prefix test" "$output"
}

test_worktree_create() {
    echo -e "${BOLD}test: worktree creation${RESET}"
    todo new "Worktree test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Link a branch name (doesn't need to exist for linking)
    todo link "$id" "https://github.com/Maybern/maybern/tree/todo/worktree-test" >/dev/null

    # Create a local branch so worktree creation works
    git -C "$TODO_REPO" branch "todo/worktree-test" 2>/dev/null

    # Manually call init worktree (since _start_session is interactive)
    # We source the script to access internal functions
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _init_worktree_for_todo "$id" >/dev/null 2>&1
    )

    local wt_path
    wt_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_not_empty "worktree_path set" "$wt_path"

    local branch
    branch=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .branch' < "$TODO_DATA_DIR/todos.json")
    assert_eq "branch preserved" "todo/worktree-test" "$branch"

    # Verify the worktree actually exists
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -d "$wt_path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} worktree directory exists"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} worktree directory exists"
    fi
}



test_done_with_worktree_cleanup() {
    echo -e "${BOLD}test: done cleans up worktree${RESET}"
    todo new "Cleanup test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Create branch and worktree
    git -C "$TODO_REPO" branch "todo/cleanup-test" 2>/dev/null
    todo link "$id" "https://github.com/Maybern/maybern/tree/todo/cleanup-test" >/dev/null
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _init_worktree_for_todo "$id" >/dev/null 2>&1
    )

    local wt_path
    wt_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")

    # Mark done (override _gum_confirm to accept cleanup)
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _gum_confirm() { return 0; }
        _archive_todo "$id" 2>&1
    )

    local status
    status=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "status is done" "done" "$status"

    # Verify worktree removed
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ ! -d "$wt_path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} worktree directory cleaned up"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} worktree directory cleaned up"
    fi

    # Verify branch deleted
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! git -C "$TODO_REPO" show-ref --verify --quiet "refs/heads/todo/cleanup-test" 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} branch deleted"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} branch deleted"
    fi
}

test_multiple_todos_isolation() {
    echo -e "${BOLD}test: multiple todos stay isolated${RESET}"
    todo new "Todo A" >/dev/null
    todo new "Todo B" >/dev/null

    local id_a id_b
    id_a=$(jq -r '.[-2].id' < "$TODO_DATA_DIR/todos.json")
    id_b=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo link "$id_a" "https://linear.app/maybern/issue/plat-100/a" >/dev/null
    todo link "$id_b" "https://linear.app/maybern/issue/core-200/b" >/dev/null

    local ticket_a ticket_b
    ticket_a=$(jq -r --arg id "$id_a" '.[] | select(.id == $id) | .linear_ticket' < "$TODO_DATA_DIR/todos.json")
    ticket_b=$(jq -r --arg id "$id_b" '.[] | select(.id == $id) | .linear_ticket' < "$TODO_DATA_DIR/todos.json")

    assert_eq "todo A has correct ticket" "PLAT-100" "$ticket_a"
    assert_eq "todo B has correct ticket" "CORE-200" "$ticket_b"

    # Done A, B stays active
    todo done "$id_a" >/dev/null
    local status_a status_b
    status_a=$(jq -r --arg id "$id_a" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    status_b=$(jq -r --arg id "$id_b" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "A is done" "done" "$status_a"
    assert_eq "B still active" "active" "$status_b"
}

test_session_cwd_tracking() {
    echo -e "${BOLD}test: session_cwd tracked on new session${RESET}"
    todo new "Session CWD test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Simulate what _launch_claude does for a new session (without exec claude)
    local session_id cwd
    session_id="test-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    cwd="$TODO_REPO"
    local updated
    updated=$(jq --arg id "$id" --arg sid "$session_id" --arg cwd "$cwd" \
        'map(if .id == $id then .session_id = $sid | .session_cwd = $cwd else . end)' < "$TODO_DATA_DIR/todos.json")
    echo "$updated" > "$TODO_DATA_DIR/todos.json"

    local stored_cwd
    stored_cwd=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .session_cwd' < "$TODO_DATA_DIR/todos.json")
    assert_eq "session_cwd stored" "$TODO_REPO" "$stored_cwd"

    local stored_sid
    stored_sid=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .session_id' < "$TODO_DATA_DIR/todos.json")
    assert_eq "session_id stored" "$session_id" "$stored_sid"
}

test_last_opened_tracking() {
    echo -e "${BOLD}test: last_opened_at tracked${RESET}"
    todo new "Last opened test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # No last_opened_at initially
    local before
    before=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .last_opened_at // "none"' < "$TODO_DATA_DIR/todos.json")
    assert_eq "no last_opened_at initially" "none" "$before"

    # Simulate what _select_todo does
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(jq --arg id "$id" --arg now "$now" \
        'map(if .id == $id then .last_opened_at = $now else . end)' < "$TODO_DATA_DIR/todos.json")
    echo "$updated" > "$TODO_DATA_DIR/todos.json"

    local after
    after=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .last_opened_at // "none"' < "$TODO_DATA_DIR/todos.json")
    assert_not_empty "last_opened_at set" "$after"
}

test_unknown_command() {
    echo -e "${BOLD}test: unknown command${RESET}"
    local output
    output=$(todo bogus 2>&1 || true)
    assert_contains "shows error" "Unknown command" "$output"
}

# ---------------------------------------------------------------------------
# New tests — comprehensive coverage of all non-interactive paths
# ---------------------------------------------------------------------------

test_version() {
    echo -e "${BOLD}test: version${RESET}"
    local output
    output=$(todo version)
    assert_contains "prints td" "td " "$output"
}

test_new_backlog() {
    echo -e "${BOLD}test: new --backlog${RESET}"
    todo new -b "Backlog item" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local group
    group=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .group' < "$TODO_DATA_DIR/todos.json")
    assert_eq "group is backlog" "backlog" "$group"

    local status
    status=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "status is active" "active" "$status"
}

test_new_quiet() {
    echo -e "${BOLD}test: new --quiet${RESET}"
    local output
    output=$(TODO_QUIET=1 todo new "Quiet todo")
    # Quiet mode should return just the ID (no "Created:" prefix)
    assert_not_contains "no Created prefix" "Created" "$output"
    # The output should be the slug ID
    assert_contains "outputs id" "quiet-todo" "$output"
}

test_list_json() {
    echo -e "${BOLD}test: list --json${RESET}"
    local output
    output=$(todo list --json)
    # Should be valid JSON
    local valid
    valid=$(echo "$output" | jq 'type' 2>/dev/null || echo "invalid")
    assert_eq "valid JSON array" '"array"' "$valid"

    # Should contain our todos
    local count
    count=$(echo "$output" | jq 'length')
    TESTS_RUN=$((TESTS_RUN + 1))
    if (( count > 0 )); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} json has todos (count: $count)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} json has todos (count: $count)"
    fi
}

test_bump() {
    echo -e "${BOLD}test: bump${RESET}"
    todo new "Bump test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Default group is "todo"
    local group
    group=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .group // "todo"' < "$TODO_DATA_DIR/todos.json")
    assert_eq "starts as todo" "todo" "$group"

    # Bump to backlog
    local output
    output=$(todo bump "$id")
    group=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .group' < "$TODO_DATA_DIR/todos.json")
    assert_eq "bumped to backlog" "backlog" "$group"
    assert_contains "shows backlog message" "backlog" "$output"

    # Bump back to todo
    output=$(todo bump "$id")
    group=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .group' < "$TODO_DATA_DIR/todos.json")
    assert_eq "bumped back to todo" "todo" "$group"
    assert_contains "shows TODO message" "TODO" "$output"
}

test_bump_cascades_to_subtasks() {
    echo -e "${BOLD}test: bump cascades to subtasks${RESET}"
    todo new "Bump parent" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo split "$parent_id" "Bump child" >/dev/null
    local child_id
    child_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Bump parent to backlog
    todo bump "$parent_id" >/dev/null

    local parent_group child_group
    parent_group=$(jq -r --arg id "$parent_id" '.[] | select(.id == $id) | .group' < "$TODO_DATA_DIR/todos.json")
    child_group=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .group' < "$TODO_DATA_DIR/todos.json")
    assert_eq "parent in backlog" "backlog" "$parent_group"
    assert_eq "child also in backlog" "backlog" "$child_group"
}

test_rename() {
    echo -e "${BOLD}test: rename${RESET}"
    todo new "Old name" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local old_notes_path
    old_notes_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    local old_dir
    old_dir=$(dirname "$old_notes_path")

    local output
    output=$(todo rename "$id" "New name")
    assert_contains "shows old name" "Old name" "$output"
    assert_contains "shows new name" "New name" "$output"

    # Check JSON updated
    local new_title
    new_title=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .title' < "$TODO_DATA_DIR/todos.json")
    assert_eq "title updated in JSON" "New name" "$new_title"

    # Check notes path updated
    local new_notes_path
    new_notes_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    assert_contains "notes_path has new name" "New name" "$new_notes_path"

    # Check directory actually moved
    local new_dir
    new_dir=$(dirname "$new_notes_path")
    assert_dir_exists "new notes dir exists" "$new_dir"
    assert_dir_not_exists "old notes dir gone" "$old_dir"
}

test_delete_force() {
    echo -e "${BOLD}test: delete --force${RESET}"
    todo new "Delete me" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local notes_path
    notes_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    local notes_dir
    notes_dir=$(dirname "$notes_path")
    assert_dir_exists "notes dir exists before delete" "$notes_dir"

    local output
    output=$(todo delete "$id" --force)
    assert_contains "shows deleted" "Deleted" "$output"

    # Verify removed from JSON
    local remaining
    remaining=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .id' < "$TODO_DATA_DIR/todos.json")
    assert_eq "removed from JSON" "" "$remaining"

    # Verify notes dir deleted
    assert_dir_not_exists "notes dir deleted" "$notes_dir"
}

test_delete_cascades_to_subtasks() {
    echo -e "${BOLD}test: delete cascades to subtasks${RESET}"
    todo new "Delete parent" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo split "$parent_id" "Delete child" >/dev/null
    local child_id
    child_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo delete "$parent_id" --force >/dev/null

    local parent_remaining child_remaining
    parent_remaining=$(jq -r --arg id "$parent_id" '.[] | select(.id == $id) | .id' < "$TODO_DATA_DIR/todos.json")
    child_remaining=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .id' < "$TODO_DATA_DIR/todos.json")
    assert_eq "parent removed" "" "$parent_remaining"
    assert_eq "child also removed" "" "$child_remaining"
}

test_link_github_pr() {
    echo -e "${BOLD}test: link github PR URL${RESET}"
    todo new "Link PR test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local pr_url="https://github.com/Maybern/maybern/pull/15530"
    local output
    output=$(todo link "$id" "$pr_url")
    assert_contains "prints confirmation" "Linked" "$output"

    local stored_pr
    stored_pr=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .github_pr' < "$TODO_DATA_DIR/todos.json")
    assert_eq "github_pr stored" "$pr_url" "$stored_pr"
}

test_link_file_path() {
    echo -e "${BOLD}test: link file path${RESET}"
    todo new "Link file test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Create a temp file to link
    local file_path="${TEST_DIR}/my-plan.md"
    echo "# My Plan" > "$file_path"

    local output
    output=$(todo link "$id" "$file_path")
    assert_contains "prints confirmation" "Linked" "$output"

    local stored_notes
    stored_notes=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    assert_contains "notes_path updated" "my-plan.md" "$stored_notes"
}

test_settings_no_file() {
    echo -e "${BOLD}test: settings (no file)${RESET}"
    local output exit_code=0
    export TODO_SETTINGS="${TEST_DIR}/nonexistent-settings.json"
    output=$(todo settings 2>&1) || exit_code=$?
    assert_contains "shows error" "No settings file" "$output"
    assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_settings_with_file() {
    echo -e "${BOLD}test: settings (with file)${RESET}"
    local settings_file="${TEST_DIR}/test-settings.json"
    cat > "$settings_file" << 'EOF'
{
  "data_dir": "~/td",
  "editor": "code"
}
EOF
    export TODO_SETTINGS="$settings_file"
    local output
    output=$(todo settings)
    assert_contains "shows data_dir" "data_dir" "$output"
    assert_contains "shows editor" "code" "$output"
}

test_browse() {
    echo -e "${BOLD}test: browse${RESET}"
    # TODO_EDITOR=true means browse runs `true <notes_dir>` which is a no-op
    todo browse
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${RESET} browse runs without error"
}

test_sync_creates_from_orphaned_dirs() {
    echo -e "${BOLD}test: sync creates todos for orphaned dirs${RESET}"
    # Create an orphaned notes directory (not linked to any todo)
    local orphan_dir="${TODO_DATA_DIR}/todo/Orphaned task"
    mkdir -p "$orphan_dir"
    cat > "${orphan_dir}/plan.md" << 'EOF'
# Orphaned task

Created: 2026-01-01 00:00

## Plan

EOF

    local output
    output=$(todo sync)
    assert_contains "shows created" "Created todo" "$output"

    # Verify a new todo was created for the orphaned dir
    local found_title
    found_title=$(jq -r '.[] | select(.title == "Orphaned task") | .title' < "$TODO_DATA_DIR/todos.json")
    assert_eq "orphaned dir got a todo" "Orphaned task" "$found_title"
}

test_sync_dry_run() {
    echo -e "${BOLD}test: sync dry run${RESET}"
    # Create another orphaned directory
    local orphan_dir="${TODO_DATA_DIR}/todo/Dry run task"
    mkdir -p "$orphan_dir"
    echo "# Dry run task" > "${orphan_dir}/plan.md"

    local count_before
    count_before=$(jq 'length' < "$TODO_DATA_DIR/todos.json")

    local output
    output=$(todo sync -n)
    assert_contains "shows would create" "Would create" "$output"
    assert_contains "shows dry run notice" "Dry run" "$output"

    # Verify no actual changes
    local count_after
    count_after=$(jq 'length' < "$TODO_DATA_DIR/todos.json")
    assert_eq "no todos created in dry run" "$count_before" "$count_after"
}

test_sync_removes_orphaned_todos() {
    echo -e "${BOLD}test: sync removes orphaned todos${RESET}"
    # Create a todo, then delete its notes directory on disk
    todo new "Will be orphaned" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")
    local notes_path
    notes_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    local notes_dir
    notes_dir=$(dirname "$notes_path")

    # Delete the notes directory on disk
    rm -rf "$notes_dir"

    local output
    output=$(todo sync)
    assert_contains "shows removed" "Removed orphaned" "$output"

    # Verify todo was removed from JSON
    local remaining
    remaining=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .id' < "$TODO_DATA_DIR/todos.json")
    assert_eq "orphaned todo removed" "" "$remaining"
}

test_done_cascades_to_subtasks() {
    echo -e "${BOLD}test: done cascades to subtasks${RESET}"
    todo new "Done parent" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo split "$parent_id" "Done child A" >/dev/null
    local child_a_id
    child_a_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo split "$parent_id" "Done child B" >/dev/null
    local child_b_id
    child_b_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Mark parent as done
    todo done "$parent_id" >/dev/null

    local parent_status child_a_status child_b_status
    parent_status=$(jq -r --arg id "$parent_id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    child_a_status=$(jq -r --arg id "$child_a_id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    child_b_status=$(jq -r --arg id "$child_b_id" '.[] | select(.id == $id) | .status' < "$TODO_DATA_DIR/todos.json")
    assert_eq "parent is done" "done" "$parent_status"
    assert_eq "child A is done" "done" "$child_a_status"
    assert_eq "child B is done" "done" "$child_b_status"
}

test_try_worktree() {
    echo -e "${BOLD}test: try${RESET}"
    todo new "Try test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Create branch, worktree, and a change in the worktree
    git -C "$TODO_REPO" branch "todo/try-test" 2>/dev/null
    todo link "$id" "https://github.com/Maybern/maybern/tree/todo/try-test" >/dev/null
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _init_worktree_for_todo "$id" >/dev/null 2>&1
    )

    local wt_path
    wt_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")

    # Make a change in the worktree
    echo "test change" > "${wt_path}/test-file.txt"
    git -C "$wt_path" add test-file.txt
    git -C "$wt_path" commit -m "test change" -q

    # Run try
    local output
    output=$(todo try "$id" 2>&1)
    assert_contains "shows created branch" "try-try-test" "$output"

    # Verify the try branch exists
    TESTS_RUN=$((TESTS_RUN + 1))
    if git -C "$TODO_REPO" show-ref --verify --quiet "refs/heads/try-try-test" 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} try branch created"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} try branch created"
    fi

    # Verify the file is in the try branch
    local file_contents
    file_contents=$(git -C "$TODO_REPO" show "try-try-test:test-file.txt" 2>/dev/null || echo "")
    assert_eq "change applied to try branch" "test change" "$file_contents"

    # Clean up: switch back to master
    git -C "$TODO_REPO" checkout master -q 2>/dev/null || git -C "$TODO_REPO" checkout main -q 2>/dev/null
}

test_try_no_worktree_error() {
    echo -e "${BOLD}test: try without worktree errors${RESET}"
    todo new "Try no wt" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local output exit_code=0
    output=$(todo try "$id" 2>&1) || exit_code=$?
    # Should fail because no worktree
    assert_contains "shows error about worktree" "no worktree" "$output"
}

test_resolve_id_suffix() {
    echo -e "${BOLD}test: ID suffix resolution${RESET}"
    todo new "Unique xyzzuf name" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Use last 8 characters as suffix — should be unique
    local suffix="${id: -8}"
    local output
    output=$(todo get "$suffix" 2>&1) || true
    assert_contains "resolves by suffix" "Unique xyzzuf name" "$output"
}

test_id_collision() {
    echo -e "${BOLD}test: ID collision handling${RESET}"
    todo new "Same title" >/dev/null
    local id1
    id1=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    todo new "Same title" >/dev/null
    local id2
    id2=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # IDs should be different (second one gets -2 suffix)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$id1" != "$id2" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} duplicate titles get unique IDs ($id1 vs $id2)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} duplicate titles get unique IDs ($id1 vs $id2)"
    fi
}

test_update_from_git_clone() {
    echo -e "${BOLD}test: update from git clone${RESET}"
    # When running from a git clone, update should tell you to use git pull
    local output
    output=$(todo update 2>&1)
    assert_contains "suggests git pull" "git pull" "$output"
}

test_split_inherits_worktree() {
    echo -e "${BOLD}test: split inherits worktree path${RESET}"
    todo new "WT parent" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Set worktree path on parent
    local updated
    updated=$(jq --arg id "$parent_id" \
        'map(if .id == $id then .worktree_path = "/fake/wt/path" else . end)' < "$TODO_DATA_DIR/todos.json")
    echo "$updated" > "$TODO_DATA_DIR/todos.json"

    todo split "$parent_id" "WT child" >/dev/null
    local child_id
    child_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    local child_wt
    child_wt=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_eq "child inherits worktree" "/fake/wt/path" "$child_wt"
}

test_split_notes_nested_under_parent() {
    echo -e "${BOLD}test: split nests notes under parent${RESET}"
    todo new "Nesting parent" >/dev/null
    local parent_id
    parent_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")
    local parent_notes
    parent_notes=$(jq -r --arg id "$parent_id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")
    local parent_dir
    parent_dir=$(dirname "$parent_notes")

    todo split "$parent_id" "Nested child" >/dev/null
    local child_id
    child_id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")
    local child_notes
    child_notes=$(jq -r --arg id "$child_id" '.[] | select(.id == $id) | .notes_path' < "$TODO_DATA_DIR/todos.json")

    # Child notes should be inside parent's directory
    assert_contains "child notes nested under parent" "$parent_dir" "$child_notes"
}

test_get_missing_id_error() {
    echo -e "${BOLD}test: get with no id errors${RESET}"
    local output exit_code=0
    output=$(todo get 2>&1) || exit_code=$?
    assert_contains "shows usage" "Usage" "$output"
    assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_get_invalid_id_error() {
    echo -e "${BOLD}test: get with invalid id errors${RESET}"
    local output exit_code=0
    output=$(todo get "totally-fake-nonexistent-id" 2>&1) || exit_code=$?
    assert_contains "shows error" "No unique todo" "$output"
    assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_subcmd_help_flag() {
    echo -e "${BOLD}test: subcommand -h flag${RESET}"
    local output
    output=$(todo new -h 2>&1) || true
    assert_contains "new shows usage" "Usage" "$output"

    output=$(todo done -h 2>&1) || true
    assert_contains "done shows usage" "Usage" "$output"

    output=$(todo get -h 2>&1) || true
    assert_contains "get shows usage" "Usage" "$output"
}

test_list_backlog_section() {
    echo -e "${BOLD}test: list shows backlog section${RESET}"
    todo new -b "Backlog list item" >/dev/null

    local output
    output=$(todo list)
    assert_contains "shows backlog header" "Backlog" "$output"
    assert_contains "shows backlog item" "Backlog list item" "$output"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Running todo CLI tests${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"
echo ""

setup

# Existing tests
test_help
test_new
test_get
test_note
test_show
test_list
test_done
test_archive
test_link_linear
test_link_github_branch
test_split
test_edit
test_resolve_id_prefix
test_worktree_create
test_done_with_worktree_cleanup
test_multiple_todos_isolation
test_session_cwd_tracking
test_last_opened_tracking
test_unknown_command

# New tests
test_version
test_new_backlog
test_new_quiet
test_list_json
test_bump
test_bump_cascades_to_subtasks
test_rename
test_delete_force
test_delete_cascades_to_subtasks
test_link_github_pr
test_link_file_path
test_settings_no_file
test_settings_with_file
test_browse
test_sync_creates_from_orphaned_dirs
test_sync_dry_run
test_sync_removes_orphaned_todos
test_done_cascades_to_subtasks
test_try_worktree
test_try_no_worktree_error
test_resolve_id_suffix
test_id_collision
test_update_from_git_clone
test_split_inherits_worktree
test_split_notes_nested_under_parent
test_get_missing_id_error
test_get_invalid_id_error
test_subcmd_help_flag
test_list_backlog_section

teardown

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"
echo -e "${BOLD}Results:${RESET} ${TESTS_RUN} tests, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
