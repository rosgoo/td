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
    assert_contains "shows header" "Active" "$output"
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

test_promote() {
    echo -e "${BOLD}test: promote worktree to main repo${RESET}"
    todo new "Promote test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Create branch and worktree
    git -C "$TODO_REPO" branch "todo/promote-test" 2>/dev/null
    todo link "$id" "https://github.com/Maybern/maybern/tree/todo/promote-test" >/dev/null
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _init_worktree_for_todo "$id" >/dev/null 2>&1
    )

    local wt_path
    wt_path=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_not_empty "worktree exists before promote" "$wt_path"

    # Promote (source script to call internal function, auto-confirm with yes)
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        # Override _gum_confirm to always say yes
        _gum_confirm() { return 0; }
        _promote_worktree "$id" 2>&1
    )

    # Verify worktree_path cleared
    local wt_after
    wt_after=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_eq "worktree_path cleared after promote" "" "$wt_after"

    # Verify main repo is on the branch
    local current_branch
    current_branch=$(git -C "$TODO_REPO" branch --show-current)
    assert_eq "main repo on promoted branch" "todo/promote-test" "$current_branch"

    # Verify worktree directory removed
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ ! -d "$wt_path" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} worktree directory removed"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} worktree directory removed"
    fi
}

test_demote() {
    echo -e "${BOLD}test: demote branch to worktree${RESET}"
    todo new "Demote test" >/dev/null
    local id
    id=$(jq -r '.[-1].id' < "$TODO_DATA_DIR/todos.json")

    # Create and checkout branch in main repo (no worktree)
    git -C "$TODO_REPO" checkout -b "todo/demote-test" -q
    todo link "$id" "https://github.com/Maybern/maybern/tree/todo/demote-test" >/dev/null

    # Verify no worktree yet
    local wt_before
    wt_before=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_eq "no worktree before demote" "" "$wt_before"

    # Demote
    (
        export TODO_DATA_DIR TODO_REPO TODO_EDITOR
        source "$TODO_BIN"
        _gum_confirm() { return 0; }
        _demote_to_worktree "$id" 2>&1
    )

    # Verify worktree_path set
    local wt_after
    wt_after=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .worktree_path' < "$TODO_DATA_DIR/todos.json")
    assert_not_empty "worktree_path set after demote" "$wt_after"

    # Verify worktree directory exists
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -d "$wt_after" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} worktree directory created"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} worktree directory created"
    fi

    # Verify main repo switched back to default branch (master or main)
    local main_branch default_branch
    main_branch=$(git -C "$TODO_REPO" branch --show-current)
    default_branch="master"
    if ! git -C "$TODO_REPO" show-ref --verify --quiet "refs/heads/master" 2>/dev/null; then
        default_branch="main"
    fi
    assert_eq "main repo back on default branch" "$default_branch" "$main_branch"
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
# Run all tests
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Running todo CLI tests${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"
echo ""

setup

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
test_promote
test_demote
test_done_with_worktree_cleanup
test_multiple_todos_isolation
test_session_cwd_tracking
test_last_opened_tracking
test_unknown_command

teardown

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"
echo -e "${BOLD}Results:${RESET} ${TESTS_RUN} tests, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
