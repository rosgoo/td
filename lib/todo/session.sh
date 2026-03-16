#!/usr/bin/env bash
# session.sh — Git worktree lifecycle and Claude Code session management.
#
# Handles creating/promoting/demoting worktrees, launching Claude with the
# right --resume / --session-id flags, and injecting plan context via
# --append-system-prompt.

# --- Worktree creation ------------------------------------------------------

_init_worktree_for_todo() {
    # Creates (or reuses) a git worktree for a todo. Uses the todo's linked
    # branch if set, otherwise creates a new "todo/<slug>" branch from master.
    # Returns the worktree path on stdout.
    local id="$1"
    _require_repo

    local todo
    todo=$(_get_todo "$id")
    local title branch
    title=$(echo "$todo" | jq -r '.title')
    branch=$(echo "$todo" | jq -r '.branch // empty')

    local slug worktree_path
    slug=$(_slugify "$title")
    worktree_path="$(_worktree_dir)/${slug}"

    # If the todo already has a branch set (via link), use it
    if [[ -z "$branch" ]]; then
        branch="${BRANCH_PREFIX}/${slug}"
    fi

    # Determine where the branch exists
    local has_local=false has_remote=false
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        has_local=true
    fi
    if git -C "$REPO_ROOT" ls-remote --heads origin "${branch}" 2>/dev/null | grep -q .; then
        has_remote=true
    fi

    if [[ "$has_local" == true ]]; then
        echo -e "${YELLOW}Branch '${branch}' already exists locally. Using it.${RESET}" >&2

        # Pull latest from remote if available
        if [[ "$has_remote" == true ]]; then
            echo -e "${DIM}Fetching latest from remote...${RESET}" >&2
            git -C "$REPO_ROOT" fetch origin "${branch}" 2>/dev/null || true
        fi

        # Check if there's already a worktree for this branch
        local existing_wt
        existing_wt=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | \
            awk -v branch="$branch" '/^worktree /{wt=$2} /^branch refs\/heads\//{b=$2; sub("refs/heads/","",b); if(b==branch) print wt}')
        if [[ -n "$existing_wt" ]]; then
            echo -e "${DIM}Found existing worktree at ${existing_wt}${RESET}" >&2
            worktree_path="$existing_wt"
        else
            mkdir -p "$(dirname "$worktree_path")"
            git -C "$REPO_ROOT" worktree add "$worktree_path" "$branch" >&2 2>&1
        fi

        # Fast-forward local branch to match remote if possible
        if [[ "$has_remote" == true ]]; then
            local ff_result
            ff_result=$(git -C "$worktree_path" merge --ff-only "origin/${branch}" 2>&1) || true
            if [[ "$ff_result" == *"Already up to date"* ]]; then
                echo -e "${DIM}Already up to date with remote.${RESET}" >&2
            elif [[ -n "$ff_result" ]]; then
                echo -e "${DIM}Updated to latest remote.${RESET}" >&2
            fi
        fi
    elif [[ "$has_remote" == true ]]; then
        # Branch exists on remote but not locally — fetch and create local tracking branch
        echo -e "${DIM}Branch '${branch}' found on remote. Fetching...${RESET}" >&2
        git -C "$REPO_ROOT" fetch origin "${branch}" 2>/dev/null
        mkdir -p "$(dirname "$worktree_path")"
        git -C "$REPO_ROOT" worktree add --track -b "$branch" "$worktree_path" "origin/${branch}" >&2 2>&1
    else
        # Branch doesn't exist anywhere — create new from master/main
        local base_branch="master"
        if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/master" 2>/dev/null; then
            base_branch="main"
        fi
        mkdir -p "$(dirname "$worktree_path")"
        echo -e "${DIM}Creating worktree on branch ${branch} from ${base_branch}...${RESET}" >&2
        git -C "$REPO_ROOT" worktree add -b "$branch" "$worktree_path" "$base_branch" >&2 2>&1
    fi

    # Update the todo record with the branch and worktree path
    local updated
    updated=$(_read_todos | jq --arg id "$id" \
        --arg branch "$branch" \
        --arg worktree_path "$worktree_path" \
        'map(if .id == $id then .branch = $branch | .worktree_path = $worktree_path else . end)')
    _write_todos "$updated"

    echo "$worktree_path"
}

# --- Try (apply worktree diff to main repo) ---------------------------------

_try_worktree() {
    # Takes all diffs from a worktree branch vs the main branch and applies
    # them as a single commit on a new "try-<slug>" branch off main in the
    # main repo checkout. This lets you test worktree changes without
    # promoting or deleting the worktree.
    local id="$1"
    _require_repo

    local todo
    todo=$(_get_todo "$id")
    local worktree_path branch title
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    title=$(echo "$todo" | jq -r '.title')

    if [[ -z "$worktree_path" ]]; then
        echo -e "${RED}Error:${RESET} This todo has no worktree. 'try' only works with worktree sessions." >&2
        return 1
    fi

    if ! _validate_worktree "$worktree_path"; then
        echo -e "${RED}Error:${RESET} Worktree at ${worktree_path} is missing or invalid." >&2
        return 1
    fi

    # Determine base branch
    local base_branch="master"
    if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/master" 2>/dev/null; then
        base_branch="main"
    fi

    # Check that there are actually changes
    local diff
    diff=$(git -C "$worktree_path" diff "${base_branch}...HEAD" 2>/dev/null)
    if [[ -z "$diff" ]]; then
        echo -e "${YELLOW}No changes${RESET} between ${base_branch} and ${branch}."
        return 0
    fi

    local slug try_branch
    slug=$(_slugify "$title")
    try_branch="try-${slug}"

    # Check for uncommitted changes in main repo
    if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
        echo -e "${RED}Error:${RESET} Main repo has uncommitted changes. Commit or stash them first." >&2
        return 1
    fi

    echo -e "${BOLD}Try:${RESET} ${title}"
    echo -e "${DIM}Applying diff from ${branch} onto ${base_branch} as ${try_branch}${RESET}"

    # Delete existing try branch if it exists
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${try_branch}" 2>/dev/null; then
        if ! _gum_confirm "Branch '${try_branch}' already exists. Replace it?"; then
            return 0
        fi
        # If main repo is on the try branch, switch off first
        local current_branch
        current_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
        if [[ "$current_branch" == "$try_branch" ]]; then
            git -C "$REPO_ROOT" checkout "$base_branch" 2>/dev/null
        fi
        git -C "$REPO_ROOT" branch -D "$try_branch" 2>/dev/null
    fi

    # Create try branch from base
    git -C "$REPO_ROOT" checkout -b "$try_branch" "$base_branch" 2>/dev/null

    # Apply the diff
    if ! echo "$diff" | git -C "$REPO_ROOT" apply --index 2>/dev/null; then
        echo -e "${RED}Error:${RESET} Failed to apply diff cleanly. Resetting." >&2
        git -C "$REPO_ROOT" checkout "$base_branch" 2>/dev/null
        git -C "$REPO_ROOT" branch -D "$try_branch" 2>/dev/null
        return 1
    fi

    # Commit
    git -C "$REPO_ROOT" commit -m "try: ${title}" 2>/dev/null

    echo -e "${GREEN}${SYM_CHECK}${RESET} Created ${BOLD}${try_branch}${RESET} with changes from ${branch}"
    echo -e "${DIM}Main repo is now on ${try_branch}. Worktree is unchanged.${RESET}"
}

# --- Claude session launching -----------------------------------------------

_launch_claude() {
    # Launches claude with plan context injected via --append-system-prompt.
    # If session_id is set, resumes. Otherwise creates a new session.
    local id="$1"
    local session_id="$2"

    # Unset CLAUDECODE to avoid nested-session issues
    unset CLAUDECODE 2>/dev/null || true

    # Build context string from plan (+ parent plan for subtasks)
    local todo notes_path context_args=()
    todo=$(_get_todo "$id")
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    local title ticket branch parent_id github_pr worktree_path
    title=$(echo "$todo" | jq -r '.title')
    ticket=$(echo "$todo" | jq -r '.linear_ticket // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    parent_id=$(echo "$todo" | jq -r '.parent_id // empty')
    github_pr=$(echo "$todo" | jq -r '.github_pr // empty')
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')

    local context="# Current Todo: ${title}"
    context="${context}\nTodo ID: ${id}"
    context="${context}\nTD Directory: ${DATA_DIR}"
    [[ -n "$ticket" ]] && context="${context}\nLinear: ${ticket}"
    [[ -n "$branch" ]] && context="${context}\nBranch: ${branch}"
    [[ -n "$github_pr" ]] && context="${context}\nGitHub PR: ${github_pr}"
    [[ -n "$worktree_path" ]] && context="${context}\nWorktree: ${worktree_path}"
    [[ -n "$notes_path" ]] && context="${context}\nPlan: ${notes_path}"

    # Append parent context for subtasks
    if [[ -n "$parent_id" ]]; then
        local parent parent_title parent_notes_path
        parent=$(_get_todo "$parent_id")
        if [[ -n "$parent" && "$parent" != "null" ]]; then
            parent_title=$(echo "$parent" | jq -r '.title')
            parent_notes_path=$(echo "$parent" | jq -r '.notes_path // empty')
            context="${context}\nParent: ${parent_title}"
            if [[ -n "$parent_notes_path" && -f "$parent_notes_path" ]]; then
                context="${context}\n\n## Parent plan\n\n$(cat "$parent_notes_path")"
            fi
        fi
    fi

    # Append own plan
    if [[ -n "$notes_path" && -f "$notes_path" ]]; then
        context="${context}\n\n## Plan\n\n$(cat "$notes_path")"
    fi

    # Instruction: persist plan mode content to the plan file
    if [[ -n "$notes_path" ]]; then
        context="${context}\n\nWhen in plan mode, always write your plan to ${notes_path} before exiting plan mode."
    fi

    context_args=(--append-system-prompt "$(echo -e "$context")")

    if [[ -n "$session_id" ]]; then
        # Verify the session file actually exists before trying --resume
        local session_file_found=false
        local encoded_cwd
        encoded_cwd=$(pwd | sed 's|/|-|g')
        local project_dir="$HOME/.claude/projects/${encoded_cwd}"
        if [[ -f "${project_dir}/${session_id}.jsonl" ]]; then
            session_file_found=true
        fi

        if [[ "$session_file_found" == true ]]; then
            echo -e "${GREEN}${SYM_SESSION}${RESET} Resuming session ${DIM}${session_id}${RESET}"
            exec claude --resume "$session_id" "${context_args[@]}"
        else
            echo -e "${YELLOW}${SYM_SESSION}${RESET} Previous session not found on disk. Starting fresh session."
            session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
            local session_cwd
            session_cwd=$(pwd)
            local updated
            updated=$(_read_todos | jq --arg id "$id" --arg sid "$session_id" --arg cwd "$session_cwd" \
                'map(if .id == $id then .session_id = $sid | .session_cwd = $cwd else . end)')
            _write_todos "$updated"
            exec claude --session-id "$session_id" "${context_args[@]}"
        fi
    else
        session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
        local session_cwd
        session_cwd=$(pwd)
        local updated
        updated=$(_read_todos | jq --arg id "$id" --arg sid "$session_id" --arg cwd "$session_cwd" \
            'map(if .id == $id then .session_id = $sid | .session_cwd = $cwd else . end)')
        _write_todos "$updated"
        echo -e "${BLUE}${SYM_SESSION}${RESET} Starting session ${DIM}${session_id}${RESET}"
        exec claude --session-id "$session_id" "${context_args[@]}"
    fi
}

_start_session() {
    # Entry point for starting/resuming a Claude session for a todo.
    # Handles: resuming existing sessions, creating worktrees, directory switching,
    # and validating that the worktree and branch are in the expected state.
    local id="$1"
    local mode="${2:-}"  # "worktree", "current-dir", or "" (has worktree already)
    local todo
    todo=$(_get_todo "$id")

    local worktree_path branch title session_id
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    title=$(echo "$todo" | jq -r '.title')
    session_id=$(echo "$todo" | jq -r '.session_id // empty')

    # --- Case 1: Session exists but no worktree — cd to the saved directory ---
    if [[ -n "$session_id" && -z "$worktree_path" ]]; then
        local session_cwd
        session_cwd=$(echo "$todo" | jq -r '.session_cwd // empty')
        if [[ -z "$session_cwd" ]] || [[ ! -d "$session_cwd" ]]; then
            # Try to discover cwd from the Claude session file
            local session_file
            session_file=$(find "$HOME/.claude/projects" -name "${session_id}.jsonl" 2>/dev/null | head -1)
            if [[ -n "$session_file" ]]; then
                session_cwd=$(head -5 "$session_file" | jq -r 'select(.cwd) | .cwd' | head -1)
            fi
            if [[ -z "$session_cwd" ]] || [[ ! -d "$session_cwd" ]]; then
                echo -e "${RED}Error:${RESET} Session ${DIM}${session_id}${RESET} has no saved directory. Re-link it:" >&2
                echo -e "  ${CYAN}td link${RESET} ${SYM_ARROW} choose \"Claude session\" and re-enter the session ID" >&2
                return 1
            fi
            # Backfill session_cwd so we don't have to discover it again
            local updated
            updated=$(_read_todos | jq --arg id "$id" --arg cwd "$session_cwd" \
                'map(if .id == $id then .session_cwd = $cwd else . end)')
            _write_todos "$updated"
        fi
        local real_cwd real_scwd
        real_cwd="$(realpath "$(pwd)" 2>/dev/null)"
        real_scwd="$(realpath "$session_cwd" 2>/dev/null)"
        if [[ "$real_cwd" != "$real_scwd" ]]; then
            if _gum_confirm "Session was started in ${session_cwd}. Switch directory?"; then
                cd "$session_cwd"
            else
                echo -e "${YELLOW}Warning:${RESET} Cannot resume session from a different directory."
                if _gum_confirm "Start a new session here instead?"; then
                    _launch_claude "$id" ""
                    return
                fi
                return 0
            fi
        fi
        _launch_claude "$id" "$session_id"
        return
    fi

    # --- Case 2: No worktree yet — create one or use current dir ---
    if [[ -z "$worktree_path" ]]; then
        case "$mode" in
            "worktree")
                _require_repo
                worktree_path=$(_init_worktree_for_todo "$id")
                todo=$(_get_todo "$id")
                branch=$(echo "$todo" | jq -r '.branch // empty')
                ;;
            "current-dir")
                _launch_claude "$id" "$session_id"
                return
                ;;
            *)
                # Interactive fallback: ask the user
                local choice
                choice=$(_gum_choose "No worktree — how to start?" \
                    "Create a worktree (new branch)" \
                    "Start Claude in current directory" \
                    "Cancel") || return 0
                case "$choice" in
                    "Create"*)
                        _require_repo
                        worktree_path=$(_init_worktree_for_todo "$id")
                        todo=$(_get_todo "$id")
                        branch=$(echo "$todo" | jq -r '.branch // empty')
                        ;;
                    "Start"*)
                        _launch_claude "$id" "$session_id"
                        return
                        ;;
                    *)
                        return 0
                        ;;
                esac
                ;;
        esac
    fi

    # --- Case 3: Worktree exists — validate and cd into it ---

    # Validate worktree still exists on disk
    if ! _validate_worktree "$worktree_path"; then
        echo -e "${YELLOW}Warning:${RESET} Worktree at ${worktree_path} is missing."
        if _gum_confirm "Recreate worktree?"; then
            _require_repo
            mkdir -p "$(dirname "$worktree_path")"
            if [[ -n "$branch" ]] && git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
                git -C "$REPO_ROOT" worktree add "$worktree_path" "$branch" 2>&1
            else
                echo -e "${RED}Error:${RESET} Branch '${branch}' no longer exists." >&2
                return 1
            fi
        else
            return 0
        fi
    fi

    # Switch to worktree directory if not already there
    local current_cwd
    current_cwd=$(pwd)
    local real_wt real_cwd
    real_wt="$(realpath "$worktree_path" 2>/dev/null || echo "$worktree_path")"
    real_cwd="$(realpath "$current_cwd" 2>/dev/null || echo "$current_cwd")"

    local switch_dir=true
    if [[ "$real_wt" != "$real_cwd" ]]; then
        if ! _gum_confirm "Session is in ${worktree_path}. Switch directory?"; then
            switch_dir=false
        fi
    fi

    # Validate branch matches what's checked out in the worktree
    local wt_branch
    wt_branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "")
    if [[ -n "$branch" && -n "$wt_branch" && "$wt_branch" != "$branch" ]]; then
        echo -e "${YELLOW}Warning:${RESET} Worktree is on branch '${wt_branch}', todo expects '${branch}'."
        if _gum_confirm "Switch to ${branch}?"; then
            local switch_result
            switch_result=$(git -C "$worktree_path" checkout "$branch" 2>&1) || true
            if [[ $? -eq 0 ]]; then
                echo -e "Switched to ${BOLD}${branch}${RESET}"
            else
                echo -e "${YELLOW}Could not switch branch:${RESET} ${switch_result}"
            fi
        fi
    fi

    if [[ "$switch_dir" == true ]]; then
        cd "$worktree_path"
    fi
    _launch_claude "$id" "$session_id"
}
