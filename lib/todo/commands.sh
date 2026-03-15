#!/usr/bin/env bash
# commands.sh — All user-facing commands (cmd_*).
#
# Each function here corresponds to a subcommand: `td new`, `td done`, etc.
# They orchestrate data, git, session, and UI functions from the other modules.

# ---------------------------------------------------------------------------
# todo new "title" — Create a new todo
# ---------------------------------------------------------------------------

cmd_new() {
    local group="todo"
    local title=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--backlog) group="backlog"; shift ;;
            *) title="$1"; shift ;;
        esac
    done

    if [[ -z "$title" ]]; then
        title=$(_gum_input "Todo title...")
        if [[ -z "$title" ]]; then
            exit 0
        fi
    fi

    local id notes_path
    id=$(_generate_id)
    notes_path="${NOTES_DIR}/$(_notes_folder_name "$id" "$title")"

    # Create plan.md
    mkdir -p "$notes_path"
    cat > "${notes_path}/plan.md" << EOF
# ${title}

Created: $(date '+%Y-%m-%d %H:%M')

## Plan

EOF

    # Add todo to JSON (no branch/worktree by default)
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(_read_todos | jq --arg id "$id" \
        --arg title "$title" \
        --arg created_at "$now" \
        --arg notes_path "${notes_path}/plan.md" \
        --arg status "active" \
        --arg group "$group" \
        '. + [{
            id: $id,
            title: $title,
            created_at: $created_at,
            branch: "",
            worktree_path: "",
            notes_path: $notes_path,
            status: $status,
            group: $group
        }]')
    _write_todos "$updated"

    local short_id="${id##*-}"
    local group_label=""
    [[ "$group" == "backlog" ]] && group_label=" ${DIM}(backlog)${RESET}"
    if [[ -n "${TODO_QUIET:-}" ]]; then
        echo "$id"
    else
        echo -e "${GREEN}${SYM_CHECK}${RESET} Created: ${BOLD}${title}${RESET}${group_label}  ${DIM}${short_id}${RESET}"
        echo -e "  ${DIM}Next: td edit ${short_id}  ·  td link ${short_id}  ·  td split ${short_id}${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# td do [-n "title"] — Create a todo and immediately open Claude
# ---------------------------------------------------------------------------

cmd_do() {
    local title=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) title="${2:-}"; shift 2 ;;
            *) title="$1"; shift ;;
        esac
    done

    if [[ -z "$title" ]]; then
        title=$(_gum_input "What are you working on?")
        if [[ -z "$title" ]]; then
            exit 0
        fi
    fi

    local id notes_path
    id=$(_generate_id)
    notes_path="${NOTES_DIR}/$(_notes_folder_name "$id" "$title")"

    # Create plan.md
    mkdir -p "$notes_path"
    cat > "${notes_path}/plan.md" << EOF
# ${title}

Created: $(date '+%Y-%m-%d %H:%M')

## Plan

EOF

    # Add todo to JSON
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(_read_todos | jq --arg id "$id" \
        --arg title "$title" \
        --arg created_at "$now" \
        --arg notes_path "${notes_path}/plan.md" \
        --arg status "active" \
        --arg group "todo" \
        '. + [{
            id: $id,
            title: $title,
            created_at: $created_at,
            branch: "",
            worktree_path: "",
            notes_path: $notes_path,
            status: $status,
            group: $group
        }]')
    _write_todos "$updated"

    local short_id="${id##*-}"
    echo -e "${GREEN}${SYM_CHECK}${RESET} Created: ${BOLD}${title}${RESET}  ${DIM}${short_id}${RESET}"

    # Launch Claude session in current directory
    _start_session "$id" "current-dir"
}

# ---------------------------------------------------------------------------
# todo split [id] ["title"] — Create a subtask under a parent todo
# ---------------------------------------------------------------------------

cmd_split() {
    local parent_id="${1:-}"
    local title="${2:-}"

    # Pick parent todo if not provided
    if [[ -z "$parent_id" ]]; then
        parent_id=$(_pick_todo "Select parent todo" "add ❯ ") || exit 0
    else
        parent_id=$(_resolve_id "$parent_id") || exit 1
    fi

    local parent
    parent=$(_get_todo "$parent_id")
    local parent_title parent_branch parent_wt
    parent_title=$(echo "$parent" | jq -r '.title')
    parent_branch=$(echo "$parent" | jq -r '.branch // empty')
    parent_wt=$(echo "$parent" | jq -r '.worktree_path // empty')

    if [[ -z "$title" ]]; then
        echo -e "${DIM}Adding subtask to: ${parent_title}${RESET}"
        title=$(_gum_input "Subtask title...") || return 0
        if [[ -z "$title" ]]; then
            return 0
        fi
    fi

    local id notes_path parent_notes_dir
    id=$(_generate_id)

    # Nest subtask notes inside parent's notes directory
    local parent_notes
    parent_notes=$(echo "$parent" | jq -r '.notes_path // empty')
    if [[ -n "$parent_notes" ]]; then
        parent_notes_dir=$(dirname "$parent_notes")
    else
        parent_notes_dir="$NOTES_DIR"
    fi
    notes_path="${parent_notes_dir}/$(_notes_folder_name "$id" "$title" "$parent_notes_dir")"

    # Create plan.md (parent context is injected dynamically via system prompt)
    mkdir -p "$notes_path"
    cat > "${notes_path}/plan.md" << EOF
# ${title}

Created: $(date '+%Y-%m-%d %H:%M')
Parent: ${parent_title}

## Plan

EOF

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(_read_todos | jq --arg id "$id" \
        --arg title "$title" \
        --arg created_at "$now" \
        --arg notes_path "${notes_path}/plan.md" \
        --arg status "active" \
        --arg parent_id "$parent_id" \
        --arg branch "$parent_branch" \
        --arg wt "$parent_wt" \
        '. + [{
            id: $id,
            title: $title,
            created_at: $created_at,
            branch: $branch,
            worktree_path: $wt,
            notes_path: $notes_path,
            status: $status,
            parent_id: $parent_id
        }]')
    _write_todos "$updated"

    if [[ -n "${TODO_QUIET:-}" ]]; then
        echo "$id"
    else
        echo -e "${GREEN}${SYM_CHECK}${RESET} Created subtask: ${BOLD}${title}${RESET}"
        echo -e "  ${DIM}Parent: ${parent_title}${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# todo done [id] — Mark a todo as done (with optional worktree/branch cleanup)
# ---------------------------------------------------------------------------

_archive_todo() {
    local id="$1"
    local todo
    todo=$(_get_todo "$id")
    local title worktree_path branch
    title=$(echo "$todo" | jq -r '.title')
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')

    # Mark this todo and all descendant subtasks as done
    local updated
    updated=$(_read_todos | jq --arg id "$id" '
        . as $all |
        def desc($pid): [$all[] | select(.parent_id == $pid) | .id] |
            if length == 0 then [] else . + (map(desc(.)) | add) end;
        ([$id] + desc($id)) as $ids |
        map(if (.id | IN($ids[])) then .status = "done" else . end)')
    _write_todos "$updated"

    echo -e "${GREEN}${SYM_CHECK}${RESET} Done: ${BOLD}${title}${RESET}"

    # Report subtasks that were also marked done
    local subtask_titles
    subtask_titles=$(echo "$updated" | jq -r --arg id "$id" '.[] | select(.parent_id == $id and .status == "done") | .title')
    if [[ -n "$subtask_titles" ]]; then
        while IFS= read -r st; do
            echo -e "  ${DIM}${SYM_CHECK} ${st}${RESET}"
        done <<< "$subtask_titles"
    fi

    # Offer to clean up git resources
    if [[ -n "$worktree_path" || -n "$branch" ]]; then
        if _gum_confirm "Remove worktree and branch?"; then
            if [[ -n "$REPO_ROOT" ]]; then
                if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
                    git -C "$REPO_ROOT" worktree remove "$worktree_path" --force 2>/dev/null || true
                    echo -e "${DIM}Removed worktree${RESET}"
                fi
                if [[ -n "$branch" ]] && git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
                    git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
                    echo -e "${DIM}Deleted branch ${branch}${RESET}"
                fi
            fi
        fi
    fi
}

cmd_done() {
    local selected_id="${1:-}"
    if [[ -n "$selected_id" ]]; then
        selected_id=$(_resolve_id "$selected_id") || exit 1
    else
        selected_id=$(_pick_todo "Select todo to mark as done" "done ❯ ") || exit 0
    fi
    _archive_todo "$selected_id"
}

# ---------------------------------------------------------------------------
# todo edit [id] — Open plan.md in $EDITOR
# ---------------------------------------------------------------------------

cmd_edit() {
    local selected_id="${1:-}"
    if [[ -n "$selected_id" ]]; then
        selected_id=$(_resolve_id "$selected_id") || exit 1
    else
        selected_id=$(_pick_todo "Select todo to edit plan" "edit ❯ ") || exit 0
    fi

    local todo
    todo=$(_get_todo "$selected_id")
    local title notes_path
    title=$(echo "$todo" | jq -r '.title')
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    if [[ -z "$notes_path" || ! -f "$notes_path" ]]; then
        notes_path=$(_ensure_notes "$selected_id" "$title")
    fi

    _open_notes "$notes_path"
}

# ---------------------------------------------------------------------------
# todo list — Print active todos
# ---------------------------------------------------------------------------

cmd_list() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    local todos
    todos=$(_active_todos)

    if [[ "$json_mode" == true ]]; then
        echo "$todos" | jq .
        return
    fi

    local count
    count=$(echo "$todos" | jq 'length')

    if (( count == 0 )); then
        echo -e "${DIM}No active todos.${RESET}"
        exit 0
    fi

    # Split into TODO and backlog groups
    local todo_items backlog_items todo_count backlog_count
    todo_items=$(echo "$todos" | jq -r '[.[] | select((.group // "todo") == "todo")]')
    backlog_items=$(echo "$todos" | jq -r '[.[] | select((.group // "todo") == "backlog")]')
    todo_count=$(echo "$todo_items" | jq 'length')
    backlog_count=$(echo "$backlog_items" | jq 'length')

    _list_section() {
        local items="$1" icon="$2"
        echo "$items" | jq -r --arg icon "$icon" '
            .[] |
            (.id | split("-") | last) as $short_id |
            "\n  \($icon) \u001b[1m\(.title)\u001b[0m  \u001b[2m\($short_id)\u001b[0m" +
            (if (.linear_ticket // "") != "" then "\n    \u001b[0;35m\(.linear_ticket)\u001b[0m" else "" end) +
            (if (.branch // "") != "" then "  \u001b[0;36m\(.branch)\u001b[0m" else "" end) +
            (if (.github_pr // "") != "" then "  \u001b[0;36m\(.github_pr)\u001b[0m" else "" end) +
            (if (.worktree_path // "") != "" then "\n    \u001b[2m\(.worktree_path)\u001b[0m" else "" end) +
            "\n    \u001b[2m\(.created_at | split("T")[0])\u001b[0m"
        ' | while IFS= read -r line; do printf '%b\n' "$line"; done
    }

    if (( todo_count > 0 )); then
        echo ""
        echo -e "  ${BOLD}TODO${RESET} ${DIM}(${todo_count})${RESET}"
        echo -e "  ${DIM}$(printf '%.0s─' {1..50})${RESET}"
        _list_section "$todo_items" "\\033[0;32m◉\\033[0m"
    fi

    if (( backlog_count > 0 )); then
        echo ""
        echo -e "  ${DIM}Backlog${RESET} ${DIM}(${backlog_count})${RESET}"
        echo -e "  ${DIM}$(printf '%.0s─' {1..50})${RESET}"
        _list_section "$backlog_items" "\\033[2m○\\033[0m"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# todo archive — Show completed todos
# ---------------------------------------------------------------------------

cmd_archive() {
    local todos
    todos=$(_done_todos)
    local count
    count=$(echo "$todos" | jq 'length')

    if (( count == 0 )); then
        echo -e "${DIM}No completed todos.${RESET}"
        exit 0
    fi

    echo ""
    echo -e "  ${BOLD}Completed${RESET} ${DIM}(${count})${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..50})${RESET}"

    echo "$todos" | jq -r '.[] |
        "\n  \\033[0;32m✓\\033[0m \\033[2m\(.title)\\033[0m" +
        (if (.linear_ticket // "") != "" then "  \\033[0;35m\(.linear_ticket)\\033[0m" else "" end) +
        (if (.branch // "") != "" then "  \\033[0;36m\(.branch)\\033[0m" else "" end) +
        "  \\033[2m\(.created_at | split("T")[0])\\033[0m"
    ' | while IFS= read -r line; do printf '%b\n' "$line"; done
    echo ""
}

# ---------------------------------------------------------------------------
# todo get <id> — Print todo as JSON
# ---------------------------------------------------------------------------

cmd_get() {
    local selected_id="${1:-}"
    if [[ -z "$selected_id" ]]; then
        echo -e "${RED}Usage:${RESET} td get <id>" >&2
        exit 1
    fi
    selected_id=$(_resolve_id "$selected_id") || exit 1
    _get_todo "$selected_id" | jq .
}

# ---------------------------------------------------------------------------
# todo note <id> "text" — Append text to a todo's plan.md
# ---------------------------------------------------------------------------

cmd_note() {
    local selected_id="${1:-}"
    local text="${2:-}"
    if [[ -z "$selected_id" || -z "$text" ]]; then
        echo -e "${RED}Usage:${RESET} td note <id> \"text to append to plan\"" >&2
        exit 1
    fi
    selected_id=$(_resolve_id "$selected_id") || exit 1

    local todo notes_path
    todo=$(_get_todo "$selected_id")
    local title
    title=$(echo "$todo" | jq -r '.title')
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    if [[ -z "$notes_path" || ! -f "$notes_path" ]]; then
        notes_path=$(_ensure_notes "$selected_id" "$title")
    fi

    echo "" >> "$notes_path"
    echo "$text" >> "$notes_path"
    echo -e "${GREEN}${SYM_CHECK}${RESET} Appended to ${DIM}${notes_path}${RESET}"
}

# ---------------------------------------------------------------------------
# todo show [id] — Print the plan.md path for a todo
# ---------------------------------------------------------------------------

cmd_show() {
    local selected_id="${1:-}"
    if [[ -n "$selected_id" ]]; then
        selected_id=$(_resolve_id "$selected_id") || exit 1
    else
        selected_id=$(_pick_todo "Select todo" "show ❯ ") || exit 0
    fi

    local todo
    todo=$(_get_todo "$selected_id")
    local notes_path
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    if [[ -z "$notes_path" || ! -f "$notes_path" ]]; then
        local title
        title=$(echo "$todo" | jq -r '.title')
        notes_path=$(_ensure_notes "$selected_id" "$title")
    fi

    echo "$notes_path"
}

# ---------------------------------------------------------------------------
# _bump_group <id> <group> — Set a todo's group (todo/backlog)
# ---------------------------------------------------------------------------

_bump_group() {
    local id="$1" new_group="$2"

    # Move this todo and all descendant subtasks to the new group
    local updated
    updated=$(_read_todos | jq --arg id "$id" --arg g "$new_group" '
        . as $all |
        def desc($pid): [$all[] | select(.parent_id == $pid) | .id] |
            if length == 0 then [] else . + (map(desc(.)) | add) end;
        ([$id] + desc($id)) as $ids |
        map(if (.id | IN($ids[])) then .group = $g else . end)')
    _write_todos "$updated"

    local todo title
    todo=$(_get_todo "$id")
    title=$(echo "$todo" | jq -r '.title')
    local short_id="${id##*-}"
    if [[ "$new_group" == "backlog" ]]; then
        echo -e "${DIM}${SYM_DOT}${RESET} Moved to backlog: ${DIM}${title}${RESET}  ${DIM}${short_id}${RESET}"
    else
        echo -e "${GREEN}${SYM_DOT}${RESET} Moved to TODO: ${BOLD}${title}${RESET}  ${DIM}${short_id}${RESET}"
    fi

    # Report subtasks that were also moved
    local subtask_titles
    subtask_titles=$(echo "$updated" | jq -r --arg id "$id" --arg g "$new_group" \
        '.[] | select(.parent_id == $id and .group == $g) | .title')
    if [[ -n "$subtask_titles" ]]; then
        while IFS= read -r st; do
            echo -e "  ${DIM}${SYM_DOT} ${st}${RESET}"
        done <<< "$subtask_titles"
    fi
}

# ---------------------------------------------------------------------------
# todo bump [id] — Toggle a todo between TODO and backlog
# ---------------------------------------------------------------------------

cmd_bump() {
    local selected_id="${1:-}"

    if [[ -z "$selected_id" ]]; then
        selected_id=$(_pick_todo "Select todo to bump" "bump ❯ ") || exit 0
    else
        selected_id=$(_resolve_id "$selected_id") || exit 1
    fi

    local todo current_group new_group
    todo=$(_get_todo "$selected_id")
    current_group=$(echo "$todo" | jq -r '.group // "todo"')

    if [[ "$current_group" == "backlog" ]]; then
        new_group="todo"
    else
        new_group="backlog"
    fi

    _bump_group "$selected_id" "$new_group"
}

# ---------------------------------------------------------------------------
# todo rename [id] ["new title"] — Rename a todo
# ---------------------------------------------------------------------------

cmd_rename() {
    local selected_id="${1:-}"
    local new_title="${2:-}"

    if [[ -z "$selected_id" ]]; then
        selected_id=$(_pick_todo "Select todo to rename" "rename ❯ ") || exit 0
    else
        selected_id=$(_resolve_id "$selected_id") || exit 1
    fi

    local todo
    todo=$(_get_todo "$selected_id")
    local old_title
    old_title=$(echo "$todo" | jq -r '.title')

    if [[ -z "$new_title" ]]; then
        new_title=$(gum input --value "$old_title" --cursor.foreground="4" --prompt "› " --prompt.foreground="4") || exit 0
        [[ -z "$new_title" ]] && exit 0
    fi

    # Rename the notes folder on disk if it exists inside NOTES_DIR
    local old_notes_path
    old_notes_path=$(echo "$todo" | jq -r '.notes_path // empty')
    local new_folder_name new_notes_path
    new_folder_name=$(_notes_folder_name "$selected_id" "$new_title")
    new_notes_path="${NOTES_DIR}/${new_folder_name}/plan.md"

    if [[ -n "$old_notes_path" ]]; then
        local old_dir new_dir
        old_dir=$(dirname "$old_notes_path")
        new_dir="${NOTES_DIR}/${new_folder_name}"
        if [[ -d "$old_dir" && "$old_dir" == "${NOTES_DIR}/"* && "$old_dir" != "$new_dir" ]]; then
            mv "$old_dir" "$new_dir"
        fi
    fi

    local updated
    updated=$(_read_todos | jq --arg id "$selected_id" --arg title "$new_title" --arg np "$new_notes_path" \
        'map(if .id == $id then .title = $title | .notes_path = $np else . end)')
    _write_todos "$updated"

    echo -e "${GREEN}${SYM_CHECK}${RESET} Renamed: ${DIM}${old_title}${RESET} ${SYM_ARROW} ${BOLD}${new_title}${RESET}"
}

# ---------------------------------------------------------------------------
# todo delete [id] [--force] — Delete a todo and all related data
# ---------------------------------------------------------------------------

cmd_delete() {
    local selected_id="${1:-}"
    local force="${2:-}"

    if [[ -z "$selected_id" ]]; then
        selected_id=$(_pick_todo "Select todo to delete" "delete ❯ ") || exit 0
    else
        selected_id=$(_resolve_id "$selected_id") || exit 1
    fi

    local todo
    todo=$(_get_todo "$selected_id")
    local title worktree_path branch notes_path
    title=$(echo "$todo" | jq -r '.title')
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    if [[ "$force" != "--force" ]]; then
        echo -e "${RED}Delete:${RESET} ${BOLD}${title}${RESET}"
        [[ -n "$worktree_path" ]] && echo -e "  ${DIM}Will remove worktree: ${worktree_path}${RESET}"
        [[ -n "$branch" ]] && echo -e "  ${DIM}Will delete branch: ${branch}${RESET}"
        [[ -n "$notes_path" ]] && echo -e "  ${DIM}Will delete plan: ${notes_path}${RESET}"
        _gum_confirm "Delete this todo and all related data?" || exit 0
    fi

    # Remove worktree
    if [[ -n "$worktree_path" && -d "$worktree_path" && -n "$REPO_ROOT" ]]; then
        git -C "$REPO_ROOT" worktree remove "$worktree_path" --force 2>/dev/null || true
        echo -e "${DIM}Removed worktree${RESET}"
    fi

    # Delete branch
    if [[ -n "$branch" && "$branch" != http* && -n "$REPO_ROOT" ]]; then
        if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
            git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
            echo -e "${DIM}Deleted branch ${branch}${RESET}"
        fi
    fi

    # Delete plan directory (only if it's inside our notes dir)
    if [[ -n "$notes_path" ]]; then
        local notes_dir
        notes_dir=$(dirname "$notes_path")
        if [[ -d "$notes_dir" && "$notes_dir" == "${NOTES_DIR}/"* ]]; then
            rm -rf "$notes_dir"
            echo -e "${DIM}Deleted plan${RESET}"
        fi
    fi

    # Recursively delete subtasks
    local subtask_ids
    subtask_ids=$(_read_todos | jq -r --arg pid "$selected_id" '[.[] | select(.parent_id == $pid) | .id] | .[]')
    for sid in $subtask_ids; do
        cmd_delete "$sid" "--force"
    done

    # Remove from todos.json
    local updated
    updated=$(_read_todos | jq --arg id "$selected_id" '[.[] | select(.id != $id)]')
    _write_todos "$updated"

    echo -e "${GREEN}${SYM_CHECK}${RESET} Deleted: ${BOLD}${title}${RESET}"
}

# ---------------------------------------------------------------------------
# todo link [id] [url|path] — Link a Linear ticket, branch, PR, session, or plan
# ---------------------------------------------------------------------------

cmd_link() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    local selected_id="" url=""

    # Two args: todo link <id> <url> (programmatic)
    if [[ -n "$arg1" && -n "$arg2" ]]; then
        selected_id=$(_resolve_id "$arg1") || return 1
        url="$arg2"
    elif [[ -n "$arg1" ]]; then
        # One arg: could be a URL (interactive pick) or an ID (interactive link type)
        if [[ "$arg1" == *"linear.app"* || "$arg1" == *"github.com"* ]]; then
            url="$arg1"
        elif [[ "$arg1" == *"/"* || "$arg1" == *.md || "$arg1" == *.txt ]]; then
            url="$arg1"
        else
            selected_id=$(_resolve_id "$arg1" 2>/dev/null) || url="$arg1"
        fi
    fi

    if [[ -z "$selected_id" ]]; then
        selected_id=$(_pick_todo "Select todo to link" "link ❯ ") || return 0
    fi

    local todo
    todo=$(_get_todo "$selected_id")
    local title
    title=$(echo "$todo" | jq -r '.title')

    # --- Auto-detect link type from URL and apply directly ---
    if [[ -n "$url" ]]; then
        if [[ "$url" == *"linear.app"* ]]; then
            local ticket_id
            ticket_id=$(_extract_linear_ticket "$url")
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg ticket "$ticket_id" \
                'map(if .id == $id then .linear_ticket = $ticket else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${MAGENTA}${ticket_id}${RESET}"
        elif [[ "$url" == *"github.com"*"/pull/"* ]]; then
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg pr "$url" \
                'map(if .id == $id then .github_pr = $pr else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${CYAN}${url}${RESET}"
        elif [[ "$url" == *"github.com"*"/tree/"* ]]; then
            local new_branch
            new_branch=$(_extract_github_branch "$url")
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg branch "$new_branch" \
                'map(if .id == $id then .branch = $branch else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${CYAN}${new_branch}${RESET}"
        elif [[ "$url" == *"/"* || "$url" == *.md || "$url" == *.txt ]]; then
            local notes_input="${url/#\~/$HOME}"
            notes_input="$(realpath "$notes_input" 2>/dev/null || echo "$notes_input")"
            if [[ ! -f "$notes_input" ]]; then
                echo -e "${YELLOW}Warning:${RESET} File does not exist yet: ${notes_input}"
            fi
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg np "$notes_input" \
                'map(if .id == $id then .notes_path = $np else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${DIM}${notes_input}${RESET}"
        else
            echo -e "${RED}Unknown URL.${RESET} Paste a Linear URL, GitHub URL, or file path." >&2
            return 1
        fi
        return
    fi

    # --- No URL — interactive link type selector ---
    local current_ticket current_branch current_session current_notes current_pr
    current_ticket=$(echo "$todo" | jq -r '.linear_ticket // empty')
    current_branch=$(echo "$todo" | jq -r '.branch // empty')
    current_session=$(echo "$todo" | jq -r '.session_id // empty')
    current_notes=$(echo "$todo" | jq -r '.notes_path // empty')
    current_pr=$(echo "$todo" | jq -r '.github_pr // empty')

    echo ""
    echo -e "${BOLD}${title}${RESET}"
    [[ -n "$current_ticket" ]] && echo -e "  ${MAGENTA}${SYM_DOT}${RESET} Linear   ${current_ticket}"
    [[ -n "$current_branch" ]] && echo -e "  ${CYAN}${SYM_BRANCH}${RESET} Branch   ${current_branch}"
    [[ -n "$current_pr" ]] && echo -e "  ${CYAN}${SYM_DOT}${RESET} PR       ${DIM}${current_pr}${RESET}"
    [[ -n "$current_session" ]] && echo -e "  ${GREEN}${SYM_SESSION}${RESET} Session  ${DIM}${current_session}${RESET}"
    [[ -n "$current_notes" ]] && echo -e "  ${DIM}📄${RESET} Plan     ${DIM}${current_notes}${RESET}"
    echo ""

    local choice
    choice=$(_gum_choose "What to link?" "Linear ticket" "Git branch" "GitHub PR" "Claude session" "Plan file") || return 0

    case "$choice" in
        "Linear"*)
            [[ -n "$current_ticket" ]] && echo -e "${DIM}Current: ${current_ticket}${RESET}"
            local raw_input
            raw_input=$(_gum_input "Linear URL or ticket ID (e.g. CORE-12207)") || return 0
            [[ -z "$raw_input" ]] && return 0
            local ticket_id
            ticket_id=$(_extract_linear_ticket "$raw_input")
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg ticket "$ticket_id" \
                'map(if .id == $id then .linear_ticket = $ticket else . end)')
            _write_todos "$updated"
            local ticket_url
            ticket_url=$(_linear_ticket_url "$ticket_id")
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${MAGENTA}${ticket_id}${RESET}"
            echo -e "  ${DIM}${ticket_url}${RESET}"
            ;;
        "Git"*)
            _require_repo
            [[ -n "$current_branch" ]] && echo -e "${DIM}Current: ${current_branch}${RESET}"
            local bchoice
            bchoice=$(_gum_choose "How?" "Enter branch name or GitHub URL" "Pick from existing branches") || return 0
            local new_branch=""
            case "$bchoice" in
                "Enter"*)
                    local raw_input
                    raw_input=$(_gum_input "Branch name or GitHub URL") || return 0
                    new_branch=$(_extract_github_branch "$raw_input")
                    ;;
                "Pick"*)
                    _check_fzf
                    new_branch=$(git -C "$REPO_ROOT" branch --format='%(refname:short)' | \
                        fzf --header "Select branch" --layout=reverse --height=~50% --border --prompt="branch ❯ ") || true
                    ;;
                *) return 0 ;;
            esac
            [[ -z "$new_branch" ]] && { echo -e "${DIM}Cancelled.${RESET}"; return 0; }
            if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${new_branch}" 2>/dev/null; then
                if git -C "$REPO_ROOT" ls-remote --heads origin "${new_branch}" 2>/dev/null | grep -q .; then
                    echo -e "${DIM}Branch '${new_branch}' exists on remote (will be fetched on session start).${RESET}"
                else
                    echo -e "${YELLOW}Warning:${RESET} Branch '${new_branch}' does not exist locally or on remote."
                    _gum_confirm "Continue anyway?" || return 0
                fi
            fi
            local existing_wt
            existing_wt=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | \
                awk -v branch="$new_branch" '/^worktree /{wt=$2} /^branch refs\/heads\//{b=$2; sub("refs/heads/","",b); if(b==branch) print wt}')
            local updated
            if [[ -n "$existing_wt" ]]; then
                echo -e "${DIM}Found existing worktree at ${existing_wt}${RESET}"
                updated=$(_read_todos | jq --arg id "$selected_id" --arg branch "$new_branch" --arg wt "$existing_wt" \
                    'map(if .id == $id then .branch = $branch | .worktree_path = $wt else . end)')
            else
                updated=$(_read_todos | jq --arg id "$selected_id" --arg branch "$new_branch" \
                    'map(if .id == $id then .branch = $branch else . end)')
            fi
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${CYAN}${new_branch}${RESET}"
            ;;
        "GitHub"*)
            local current_pr
            current_pr=$(echo "$todo" | jq -r '.github_pr // empty')
            [[ -n "$current_pr" ]] && echo -e "${DIM}Current: ${current_pr}${RESET}"
            local pr_input
            pr_input=$(_gum_input "GitHub PR URL") || return 0
            [[ -z "$pr_input" ]] && return 0
            if [[ "$pr_input" != *"github.com"*"/pull/"* ]]; then
                echo -e "${RED}Not a valid GitHub PR URL.${RESET}" >&2
                return 1
            fi
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg pr "$pr_input" \
                'map(if .id == $id then .github_pr = $pr else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${CYAN}${pr_input}${RESET}"
            ;;
        "Claude"*)
            [[ -n "$current_session" ]] && echo -e "${DIM}Current: ${current_session}${RESET}"
            local new_session
            new_session=$(_gum_input "Claude session UUID") || return 0
            [[ -z "$new_session" ]] && return 0
            # Discover the real cwd from the Claude session file
            local link_cwd=""
            local session_file
            session_file=$(find "$HOME/.claude/projects" -name "${new_session}.jsonl" 2>/dev/null | head -1)
            if [[ -n "$session_file" ]]; then
                link_cwd=$(head -5 "$session_file" | jq -r 'select(.cwd) | .cwd' | head -1)
            fi
            if [[ -z "$link_cwd" ]]; then
                link_cwd="$(pwd)"
            fi
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg sid "$new_session" --arg cwd "$link_cwd" \
                'map(if .id == $id then .session_id = $sid | .session_cwd = $cwd else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${GREEN}${SYM_SESSION} ${new_session}${RESET}"
            ;;
        "Plan"*)
            [[ -n "$current_notes" ]] && echo -e "${DIM}Current: ${current_notes}${RESET}"
            local notes_input
            notes_input=$(_gum_input "Path to plan file (e.g. ~/vault/my-plan.md)") || return 0
            [[ -z "$notes_input" ]] && return 0
            notes_input="${notes_input/#\~/$HOME}"
            notes_input="$(realpath "$notes_input" 2>/dev/null || echo "$notes_input")"
            if [[ ! -f "$notes_input" ]]; then
                echo -e "${YELLOW}File does not exist yet.${RESET}"
                _gum_confirm "Link anyway?" || return 0
            fi
            local updated
            updated=$(_read_todos | jq --arg id "$selected_id" --arg np "$notes_input" \
                'map(if .id == $id then .notes_path = $np else . end)')
            _write_todos "$updated"
            echo -e "${GREEN}${SYM_CHECK}${RESET} Linked: ${BOLD}${title}${RESET} ${SYM_ARROW} ${DIM}${notes_input}${RESET}"
            ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# todo open — Open Linear/GitHub links in the browser
# ---------------------------------------------------------------------------

cmd_open() {
    local selected_id
    selected_id=$(_pick_todo "Select todo to open in browser" "open ❯ ") || exit 0

    local todo
    todo=$(_get_todo "$selected_id")
    local title branch ticket
    title=$(echo "$todo" | jq -r '.title')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    ticket=$(echo "$todo" | jq -r '.linear_ticket // empty')

    local options=()
    local urls=()

    if [[ -n "$ticket" ]]; then
        local ticket_url
        ticket_url=$(_linear_ticket_url "$ticket")
        options+=("Linear: ${ticket} (${ticket_url})")
        urls+=("$ticket_url")
    fi
    if [[ -n "$branch" ]]; then
        local branch_url
        branch_url=$(_github_branch_url "$branch")
        if [[ -n "$branch_url" ]]; then
            options+=("GitHub: ${branch} (${branch_url})")
            urls+=("$branch_url")
        fi
    fi

    if [[ ${#options[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No links to open.${RESET} Use 'td link' to add a Linear ticket or branch."
        exit 0
    fi

    if [[ ${#options[@]} -eq 1 ]]; then
        echo -e "${DIM}Opening ${urls[0]}${RESET}"
        _open_url "${urls[0]}"
        exit 0
    fi

    options+=("Open all")
    local choice
    choice=$(_gum_choose "${title}" "${options[@]}") || exit 0
    if [[ "$choice" == "Open all" ]]; then
        for url in "${urls[@]}"; do
            echo -e "${DIM}Opening ${url}${RESET}"
            _open_url "$url"
        done
    else
        for i in "${!options[@]}"; do
            if [[ "${options[$i]}" == "$choice" ]]; then
                echo -e "${DIM}Opening ${urls[$i]}${RESET}"
                _open_url "${urls[$i]}"
                break
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# todo try [id] — Apply worktree diff to a try branch on main repo
# ---------------------------------------------------------------------------

cmd_try() {
    local selected_id="${1:-}"
    if [[ -n "$selected_id" ]]; then
        selected_id=$(_resolve_id "$selected_id") || exit 1
    else
        selected_id=$(_pick_todo "Select todo to try" "try ❯ ") || exit 0
    fi
    _try_worktree "$selected_id"
}

# ---------------------------------------------------------------------------
# Interactive picker (default command) — select todo and take action
# ---------------------------------------------------------------------------

_select_todo() {
    # Called when a todo is selected from the picker.
    # Shows todo details, then offers contextual actions.
    local id="$1"
    local todo
    todo=$(_get_todo "$id")

    if [[ -z "$todo" || "$todo" == "null" ]]; then
        echo -e "${RED}Error:${RESET} Todo not found." >&2
        exit 1
    fi

    local title notes_path
    title=$(echo "$todo" | jq -r '.title')
    notes_path=$(echo "$todo" | jq -r '.notes_path // empty')

    if [[ -z "$notes_path" || ! -f "$notes_path" ]]; then
        notes_path=$(_ensure_notes "$id" "$title")
    fi

    # Track last opened time
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(_read_todos | jq --arg id "$id" --arg now "$now" \
        'map(if .id == $id then .last_opened_at = $now else . end)')
    _write_todos "$updated"

    local worktree_path branch ticket session_id parent_id github_pr group
    worktree_path=$(echo "$todo" | jq -r '.worktree_path // empty')
    branch=$(echo "$todo" | jq -r '.branch // empty')
    ticket=$(echo "$todo" | jq -r '.linear_ticket // empty')
    session_id=$(echo "$todo" | jq -r '.session_id // empty')
    parent_id=$(echo "$todo" | jq -r '.parent_id // empty')
    github_pr=$(echo "$todo" | jq -r '.github_pr // empty')
    group=$(echo "$todo" | jq -r '.group // "todo"')

    # Show current state (omit metadata that matches parent for subtasks)
    echo ""
    echo -e "${BOLD}${title}${RESET}"

    local show_ticket=true show_branch=true show_wt=true
    if [[ -n "$parent_id" ]]; then
        local parent
        parent=$(_get_todo "$parent_id")
        if [[ -n "$parent" && "$parent" != "null" ]]; then
            local p_ticket p_branch p_wt
            p_ticket=$(echo "$parent" | jq -r '.linear_ticket // empty')
            p_branch=$(echo "$parent" | jq -r '.branch // empty')
            p_wt=$(echo "$parent" | jq -r '.worktree_path // empty')
            [[ -n "$ticket" && "$ticket" == "$p_ticket" ]] && show_ticket=false
            [[ -n "$branch" && "$branch" == "$p_branch" ]] && show_branch=false
            [[ -n "$worktree_path" && "$worktree_path" == "$p_wt" ]] && show_wt=false
        fi
    fi

    [[ -n "$ticket" && "$show_ticket" == true ]] && echo -e "  ${MAGENTA}${SYM_DOT}${RESET} Linear    ${ticket}"
    [[ -n "$branch" && "$show_branch" == true ]] && echo -e "  ${CYAN}${SYM_BRANCH}${RESET} Branch    ${branch}"
    [[ -n "$github_pr" ]] && echo -e "  ${CYAN}${SYM_DOT}${RESET} PR        ${DIM}${github_pr}${RESET}"
    [[ -n "$worktree_path" && "$show_wt" == true ]] && echo -e "  ${DIM}${SYM_DOT} Worktree  ${worktree_path}${RESET}"
    [[ -n "$session_id" ]] && echo -e "  ${GREEN}${SYM_SESSION}${RESET} Session   ${DIM}${session_id}${RESET}"
    echo ""

    # Build contextual action menu
    local options=()
    if [[ -n "$session_id" ]]; then
        options+=("Resume Claude session")
    elif [[ -n "$worktree_path" ]]; then
        options+=("Start Claude session")
    else
        options+=("Start Claude (current dir)")
        options+=("Start Claude (new worktree)")
    fi
    [[ -n "$worktree_path" && -n "$branch" ]] && options+=("Try on main repo")
    options+=("Mark as done")
    if [[ "$group" == "backlog" ]]; then
        options+=("Move to TODO")
    else
        options+=("Move to backlog")
    fi
    options+=("Add subtask")
    options+=("Edit plan")
    [[ -n "$ticket" || -n "$github_pr" || -n "$branch" ]] && options+=("Open")
    options+=("Link" "Back")

    local choice
    choice=$(_action_menu "What next?" "${options[@]}") || return 0
    case "$choice" in
        "Resume Claude session"|"Start Claude session")
            _start_session "$id"
            ;;
        "Start Claude (new worktree)")
            _start_session "$id" "worktree"
            ;;
        "Start Claude (current dir)")
            _start_session "$id" "current-dir"
            ;;
        "Try on main repo")
            _try_worktree "$id"
            ;;
        "Mark as done")
            _archive_todo "$id"
            ;;
        "Move to TODO")
            _bump_group "$id" "todo"
            ;;
        "Move to backlog")
            _bump_group "$id" "backlog"
            ;;
        "Add subtask")
            cmd_split "$id"
            ;;
        "Edit plan")
            _open_notes "$notes_path"
            ;;
        "Open")
            local open_urls=()
            if [[ -n "$ticket" ]]; then
                local ticket_url
                ticket_url=$(_linear_ticket_url "$ticket")
                open_urls+=("$ticket_url")
            fi
            if [[ -n "$github_pr" ]]; then
                open_urls+=("$github_pr")
            elif [[ -n "$branch" ]]; then
                local branch_url
                branch_url=$(_github_branch_url "$branch")
                [[ -n "$branch_url" ]] && open_urls+=("$branch_url")
            fi
            for url in "${open_urls[@]}"; do
                echo -e "${DIM}Opening ${url}${RESET}"
                _open_url "$url"
            done
            ;;
        "Link")
            cmd_link "$id"
            ;;
        *)
            return 0
            ;;
    esac
}

cmd_picker() {
    # The main interactive loop: shows fzf picker, dispatches to _select_todo or cmd_new.
    _check_fzf
    local show_done=false

    while true; do
        # Build grouped fzf input: TODO items, then separator, then backlog items
        local todo_lines backlog_lines
        todo_lines=$(_format_fzf_lines "$show_done" "todo")
        backlog_lines=$(_format_fzf_lines "$show_done" "backlog")

        # Prepend "New todo" option
        local input="__new__\t\t\t            ✦ New todo"
        if [[ -n "$todo_lines" ]]; then
            input="${input}\n${todo_lines}"
        fi
        if [[ -n "$backlog_lines" ]]; then
            input="${input}\n__sep__\t\t\t\033[2m  ─── Backlog ───────────────────────────────────────────────────────────────────────────────────────────\033[0m"
            input="${input}\n${backlog_lines}"
        fi

        local header="TODOs — enter: open · ctrl-d: toggle done · esc: quit"

        local result key
        result=$(echo -e "$input" | fzf \
            --header "$header" \
            --layout=reverse \
            --height=80% \
            --with-nth=4.. \
            --no-hscroll \
            --delimiter=$'\t' \
            --header-first \
            --border \
            --ansi \
            --no-multi \
            --no-sort \
            --prompt="❯ " \
            --preview-window=hidden \
            --expect=ctrl-d \
        ) || true

        if [[ -z "$result" ]]; then
            exit 0
        fi

        key=$(echo "$result" | head -1)
        result=$(echo "$result" | tail -n +2)

        if [[ "$key" == "ctrl-d" ]]; then
            if [[ "$show_done" == "true" ]]; then
                show_done=false
            else
                show_done=true
            fi
            continue
        fi

        if [[ -z "$result" ]]; then
            exit 0
        fi

        local selected_id
        selected_id=$(echo "$result" | cut -f1)

        if [[ "$selected_id" == "__new__" ]]; then
            local title
            title=$(_gum_input "Todo title...") || continue
            if [[ -n "$title" ]]; then
                cmd_new "$title"
            fi
            continue
        fi

        # Skip separator line
        if [[ "$selected_id" == "__sep__" ]]; then
            continue
        fi

        _select_todo "$selected_id"
    done
}

# ---------------------------------------------------------------------------
# td browse — Open the notes directory in $EDITOR
# ---------------------------------------------------------------------------

cmd_browse() {
    _open_notes "$NOTES_DIR"
}

# ---------------------------------------------------------------------------
# td clean — Remove orphaned todos and notes directories
# ---------------------------------------------------------------------------

cmd_sync() {
    local dry_run=false
    [[ "${1:-}" == @(-n|--dry-run) ]] && dry_run=true

    local created_todos=0 removed_todos=0

    # 1) Create todos for orphaned notes directories
    if [[ -d "$NOTES_DIR" ]]; then
        _sync_create_from_dirs "$NOTES_DIR" "" "$dry_run"
    fi

    # 2) Find todos whose notes directory no longer exists on disk
    local orphan_ids
    orphan_ids=$(_read_todos | jq -r '.[] | select(.notes_path != null and .notes_path != "") | select(.notes_path | tostring | length > 0) | .id' )

    for id in $orphan_ids; do
        local todo notes_path title
        todo=$(_get_todo "$id")
        notes_path=$(echo "$todo" | jq -r '.notes_path // empty')
        title=$(echo "$todo" | jq -r '.title')
        [[ -z "$notes_path" ]] && continue

        local notes_dir
        notes_dir=$(dirname "$notes_path")
        if [[ ! -d "$notes_dir" ]]; then
            if $dry_run; then
                echo -e "${DIM}Would remove todo:${RESET} ${BOLD}${title}${RESET} ${DIM}(${id})${RESET}"
            else
                # Recursively remove subtasks first
                local subtask_ids
                subtask_ids=$(_read_todos | jq -r --arg pid "$id" '[.[] | select(.parent_id == $pid) | .id] | .[]')
                for sid in $subtask_ids; do
                    local stodo stitle
                    stodo=$(_get_todo "$sid")
                    stitle=$(echo "$stodo" | jq -r '.title')
                    local updated
                    updated=$(_read_todos | jq --arg id "$sid" '[.[] | select(.id != $id)]')
                    _write_todos "$updated"
                    echo -e "${DIM}Removed orphaned subtask:${RESET} ${BOLD}${stitle}${RESET}"
                    ((removed_todos++)) || true
                done
                local updated
                updated=$(_read_todos | jq --arg id "$id" '[.[] | select(.id != $id)]')
                _write_todos "$updated"
                echo -e "${DIM}Removed orphaned todo:${RESET} ${BOLD}${title}${RESET}"
                ((removed_todos++)) || true
            fi
        fi
    done

    if $dry_run; then
        echo -e "\n${DIM}Dry run — no changes made. Run ${CYAN}td sync${DIM} to apply.${RESET}"
    elif (( created_todos == 0 && removed_todos == 0 )); then
        echo -e "${GREEN}${SYM_CHECK}${RESET} Already in sync"
    else
        local parts=()
        (( created_todos > 0 )) && parts+=("created ${created_todos}")
        (( removed_todos > 0 )) && parts+=("removed ${removed_todos}")
        local IFS=", "
        echo -e "${GREEN}${SYM_CHECK}${RESET} Synced: ${parts[*]}"
    fi
}

# _sync_create_from_dirs — Create todos for orphaned directories (recursive).
# Args: base_dir parent_id dry_run
_sync_create_from_dirs() {
    local base_dir="$1" parent_id="$2" dry_run="$3"

    for dir in "$base_dir"/*/; do
        [[ ! -d "$dir" ]] && continue
        dir="${dir%/}"

        # Check if any todo already references this directory
        local dir_matched
        dir_matched=$(_read_todos | jq -r --arg dir "$dir" \
            '[.[] | select(.notes_path != null and .notes_path != "") | select((.notes_path | split("/")[:-1] | join("/")) == $dir)] | length')
        [[ "$dir_matched" != "0" ]] && continue

        # Extract title from plan.md heading, fall back to folder name
        local title
        if [[ -f "${dir}/plan.md" ]]; then
            title=$(head -1 "${dir}/plan.md" | sed 's/^# *//')
        fi
        [[ -z "${title:-}" ]] && title=$(basename "$dir")

        if $dry_run; then
            local label="${title}"
            [[ -n "$parent_id" ]] && label="  ↳ ${title}"
            echo -e "${DIM}Would create todo:${RESET} ${BOLD}${label}${RESET}"
            # Still recurse subdirs in dry-run
            _sync_create_from_dirs "$dir" "dry-run-parent" "$dry_run"
        else
            local id now notes_path
            id=$(_generate_id)
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            notes_path="${dir}/plan.md"

            # Create plan.md if it doesn't exist
            if [[ ! -f "$notes_path" ]]; then
                cat > "$notes_path" << EOF
# ${title}

Created: $(date '+%Y-%m-%d %H:%M')

## Plan

EOF
            fi

            # Build the todo JSON entry
            local new_todo
            if [[ -n "$parent_id" ]]; then
                new_todo=$(jq -n --arg id "$id" --arg title "$title" \
                    --arg created_at "$now" --arg notes_path "$notes_path" \
                    --arg parent_id "$parent_id" \
                    '{id: $id, title: $title, created_at: $created_at, branch: "", worktree_path: "", notes_path: $notes_path, status: "active", group: "todo", parent_id: $parent_id}')
            else
                new_todo=$(jq -n --arg id "$id" --arg title "$title" \
                    --arg created_at "$now" --arg notes_path "$notes_path" \
                    '{id: $id, title: $title, created_at: $created_at, branch: "", worktree_path: "", notes_path: $notes_path, status: "active", group: "todo"}')
            fi

            local updated
            updated=$(_read_todos | jq --argjson todo "$new_todo" '. + [$todo]')
            _write_todos "$updated"

            local short_id="${id##*-}"
            local label="${title}"
            [[ -n "$parent_id" ]] && label="  ↳ ${title}"
            echo -e "${DIM}Created todo:${RESET} ${BOLD}${label}${RESET} ${DIM}(${short_id})${RESET}"
            ((created_todos++)) || true

            # Recurse into subdirectories for subtasks
            _sync_create_from_dirs "$dir" "$id" "$dry_run"
        fi
    done
}

# ---------------------------------------------------------------------------
# td find [query] — Search Claude sessions, create a todo, and resume
# ---------------------------------------------------------------------------

_build_session_lines() {
    # Scans ~/.claude/projects/*/*.jsonl and builds fzf-ready lines.
    # Optional query argument filters sessions by content.
    #
    # Strategy: sort files by mtime, process most recent first, use head -100
    # per file and a single jq -s call to extract metadata quickly.
    # Without a query, only processes the most recent N files (skip_limit).
    # With a query, pre-filters with grep -li before parsing.
    local query="${1:-}"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    local projects_dir="${HOME}/.claude/projects"
    local max_results=50
    local skip_limit=80  # Without a query, only scan the N most recent files
    local now_epoch today_start yesterday_start
    now_epoch=$(date +%s)
    today_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null || date -d "today 00:00:00" +%s 2>/dev/null || echo "$now_epoch")
    yesterday_start=$((today_start - 86400))

    if [[ ! -d "$projects_dir" ]]; then
        return
    fi

    # Build file list: sorted by mtime (newest first), optionally filtered by query
    local file_list
    if [[ -n "$query_lower" ]]; then
        # With query: grep first (fast), then sort by mtime
        file_list=$(grep -rli "$query_lower" "$projects_dir" --include='*.jsonl' 2>/dev/null | \
            xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | cut -d' ' -f2- | head -n "$skip_limit")
    else
        # Without query: just take the most recent files
        file_list=$(find "$projects_dir" -name '*.jsonl' -type f -print0 2>/dev/null | \
            xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | cut -d' ' -f2- | head -n "$skip_limit")
    fi

    [[ -z "$file_list" ]] && return

    # The jq filter to extract session metadata from head of each file
    local jq_filter
    jq_filter='
        . as $lines |
        (first($lines[] | select(.cwd) | .cwd) // "") as $cwd |
        (first($lines[] | select(.gitBranch) | .gitBranch) // "") as $branch |
        [
            $lines[]
            | select(.message.role == "user")
            | .message.content
            | if type == "string" then .
              elif type == "array" then [.[] | select(type == "object") | select(.type == "text" or (.type | not)) | .text // ""] | join(" ")
              else tostring
              end
            | gsub("<[^>]+>"; "") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
            | select(length > 15)
            | select(startswith("<local-command") | not)
            | select(startswith("<command-") | not)
            | select(startswith("Caveat:") | not)
        ] as $msgs |
        (if ($q | length) > 0 then
            first($msgs[] | select(ascii_downcase | contains($q))) // null
        else null end) as $match |
        if ($msgs | length) == 0 then empty
        else
            ($match // $msgs[0])[0:120] + "\t" +
            (if $match then "10" else "0" end) + "\t" +
            $cwd + "\t" + $branch
        end
    '

    # Collect raw TSV lines: mtime \t score \t session_id \t cwd \t branch \t display_line
    # Pre-load session IDs already linked to todos so we can skip them
    local linked_sessions
    linked_sessions=$(_read_todos | jq -r '[.[] | .session_id // empty] | join("\n")')

    local raw_lines=""

    while IFS= read -r fpath; do
        [[ -z "$fpath" || ! -f "$fpath" ]] && continue

        local session_id mtime_epoch
        session_id=$(basename "$fpath" .jsonl)

        # Skip subagent sessions and sessions already linked to a todo
        [[ "$session_id" == agent-* ]] && continue
        if echo "$linked_sessions" | grep -qF "$session_id"; then
            continue
        fi

        mtime_epoch=$(stat -f '%m' "$fpath" 2>/dev/null || stat -c '%Y' "$fpath" 2>/dev/null || echo "$now_epoch")

        local meta
        meta=$(head -100 "$fpath" | jq -r -s --arg q "$query_lower" "$jq_filter" 2>/dev/null) || continue
        [[ -z "$meta" ]] && continue

        local display_msg score cwd branch
        display_msg=$(printf '%s' "$meta" | cut -f1)
        score=$(printf '%s' "$meta" | cut -f2)
        cwd=$(printf '%s' "$meta" | cut -f3)
        branch=$(printf '%s' "$meta" | cut -f4)

        # Age display
        local age
        if (( mtime_epoch >= today_start )); then
            age="today"
        elif (( mtime_epoch >= yesterday_start )); then
            age="yesterday"
        else
            local diff=$(( now_epoch - mtime_epoch ))
            if (( diff < 604800 )); then
                age="$(( diff / 86400 ))d ago"
            else
                age=$(date -r "$mtime_epoch" '+%b %d' 2>/dev/null || date -d "@$mtime_epoch" '+%b %d' 2>/dev/null || echo "old")
            fi
        fi

        local project_name
        project_name=$(basename "${cwd:-unknown}" 2>/dev/null || echo "unknown")

        local age_col proj_col branch_col
        printf -v age_col '%-10s' "$age"
        printf -v proj_col '%-16s' "${project_name:0:16}"
        printf -v branch_col '%-30s' "${branch:0:30}"

        local display_line="${age_col}  ${proj_col}  ${branch_col}  ${display_msg}"

        raw_lines+="${mtime_epoch}"$'\t'"${score}"$'\t'"${session_id}"$'\t'"${cwd}"$'\t'"${branch}"$'\t'"${display_line}"$'\n'

    done <<< "$file_list"

    if [[ -z "$raw_lines" ]]; then
        return
    fi

    # Sort by score desc then mtime desc, take top N, output as session_id \t cwd \t branch \t display
    echo -n "$raw_lines" | sort -t$'\t' -k2,2rn -k1,1rn | head -n "$max_results" | while IFS=$'\t' read -r _mtime _score sid cwd branch display; do
        printf '%s\t%s\t%s\t%s\n' "$sid" "$cwd" "$branch" "$display"
    done
}

cmd_find() {
    local query="${*:-}"
    _check_fzf

    echo -e "${DIM}Scanning sessions…${RESET}" >&2

    local fzf_lines
    fzf_lines=$(_build_session_lines "$query")

    if [[ -z "$fzf_lines" ]]; then
        echo -e "${YELLOW}No sessions found.${RESET}" >&2
        exit 0
    fi

    local header="Select a session to adopt as a todo (ESC to cancel)"
    if [[ -n "$query" ]]; then
        header="Sessions matching \"${query}\" — select to adopt (ESC to cancel)"
    fi

    local result
    result=$(echo -e "$fzf_lines" | fzf \
        --header "$header" \
        --layout=reverse \
        --height=80% \
        --with-nth=4.. \
        --delimiter=$'\t' \
        --header-first \
        --border \
        --ansi \
        --no-multi \
        --no-sort \
        --prompt="find ❯ " \
        --preview-window=hidden \
    ) || true

    if [[ -z "$result" ]]; then
        exit 0
    fi

    local session_id session_cwd session_branch
    session_id=$(echo "$result" | cut -f1)
    session_cwd=$(echo "$result" | cut -f2)
    session_branch=$(echo "$result" | cut -f3)

    # Ask for a name
    local title
    title=$(_gum_input "Todo title for this session...") || exit 0
    if [[ -z "$title" ]]; then
        exit 0
    fi

    # Create the todo
    local id
    TODO_QUIET=1 id=$(cmd_new "$title")

    # Link the session
    local updated
    updated=$(_read_todos | jq --arg id "$id" --arg sid "$session_id" --arg cwd "$session_cwd" --arg branch "$session_branch" \
        'map(if .id == $id then
            .session_id = $sid |
            .session_cwd = $cwd |
            (if $branch != "" then .branch = $branch else . end)
        else . end)')
    _write_todos "$updated"

    local short_id="${id##*-}"
    echo -e "${GREEN}${SYM_CHECK}${RESET} Created: ${BOLD}${title}${RESET}  ${DIM}${short_id}${RESET}"
    echo -e "  ${GREEN}${SYM_SESSION}${RESET} Session: ${DIM}${session_id}${RESET}"
    [[ -n "$session_branch" ]] && echo -e "  ${CYAN}${SYM_BRANCH}${RESET} Branch: ${session_branch}"

    # Resume the session
    _start_session "$id"
}

# ---------------------------------------------------------------------------
# td help — Show usage
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# td update — Update td to the latest version
# ---------------------------------------------------------------------------

cmd_update() {
    local repo="rosgoo/td"
    local bin_dir="${HOME}/.local/bin"
    local lib_dir="${HOME}/.local/lib/todo"

    # Check if running from a git clone (dev mode)
    local self
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")"
    local self_dir
    self_dir="$(dirname "$(dirname "$(dirname "$self")")")"
    if [[ -d "${self_dir}/.git" ]]; then
        echo -e "${DIM}Running from git clone at ${self_dir}${RESET}"
        echo -e "${DIM}Use 'git pull && ./install.sh' to update.${RESET}"
        return 0
    fi

    echo -e "${DIM}Checking for updates...${RESET}"

    local latest
    latest=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')

    if [[ -z "$latest" ]]; then
        echo -e "${RED}✗${RESET} Could not fetch latest version from GitHub" >&2
        return 1
    fi

    local latest_ver="${latest#v}"
    local current_ver="${TODO_VERSION}"

    if [[ "$latest_ver" == "$current_ver" ]]; then
        echo -e "${GREEN}✓${RESET} Already up to date (${current_ver})"
        return 0
    fi

    echo -e "  ${DIM}Current: ${current_ver}${RESET}"
    echo -e "  ${BOLD}Latest:  ${latest_ver}${RESET}"
    echo ""

    # Download and extract
    local tarball_url="https://github.com/${repo}/archive/refs/tags/${latest}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    echo -e "${DIM}Downloading ${latest}...${RESET}"
    if ! curl -fsSL "$tarball_url" | tar xz -C "$tmp_dir"; then
        echo -e "${RED}✗${RESET} Download failed" >&2
        return 1
    fi

    local src_dir="${tmp_dir}/td-${latest_ver}"
    if [[ ! -d "$src_dir" ]]; then
        src_dir=$(find "$tmp_dir" -maxdepth 1 -type d ! -name "$(basename "$tmp_dir")" | head -1)
    fi

    # Install files
    mkdir -p "$lib_dir" "$bin_dir"
    cp "${src_dir}"/lib/todo/*.sh "$lib_dir/"
    cp "${src_dir}/td" "${bin_dir}/td" && chmod +x "${bin_dir}/td"
    cp "${src_dir}/VERSION" "${HOME}/.local/VERSION"

    if [[ -f "${src_dir}/hooks/pre-compact" ]]; then
        cp "${src_dir}/hooks/pre-compact" "${bin_dir}/td-pre-compact"
        chmod +x "${bin_dir}/td-pre-compact"
    fi

    if [[ -f "${src_dir}/commands/td.md" ]]; then
        mkdir -p "${HOME}/.claude/commands"
        cp "${src_dir}/commands/td.md" "${HOME}/.claude/commands/td.md"
    fi

    echo -e "${GREEN}✓${RESET} Updated td ${current_ver} → ${latest_ver}"
}

# ---------------------------------------------------------------------------
# td init — Initialize td in the current repo + configure settings
# ---------------------------------------------------------------------------

cmd_init() {
    _check_jq

    local settings_file="${TODO_SETTINGS}"
    local settings_dir
    settings_dir="$(dirname "$settings_file")"

    echo ""
    echo -e "${BOLD}td init${RESET} — Configure td settings"
    echo ""

    # Load existing values (if settings file exists)
    local cur_data_dir="" cur_editor="" cur_linear_org="" cur_worktree_dir="" cur_branch_prefix=""
    if [[ -f "$settings_file" ]]; then
        cur_data_dir=$(jq -r '.data_dir // empty' "$settings_file" 2>/dev/null || true)
        cur_editor=$(jq -r '.editor // empty' "$settings_file" 2>/dev/null || true)
        cur_linear_org=$(jq -r '.linear_org // empty' "$settings_file" 2>/dev/null || true)
        cur_worktree_dir=$(jq -r '.worktree_dir // empty' "$settings_file" 2>/dev/null || true)
        cur_branch_prefix=$(jq -r '.branch_prefix // empty' "$settings_file" 2>/dev/null || true)
    fi

    # Defaults
    : "${cur_data_dir:="~/td"}"
    : "${cur_editor:=""}"
    : "${cur_worktree_dir:=".claude/worktrees"}"
    : "${cur_branch_prefix:="todo"}"

    # Ask about each setting
    echo -e "  ${BOLD}data_dir${RESET} — Where todos and notes are stored"
    echo -e "  ${DIM}Current: ${cur_data_dir}${RESET}"
    local new_data_dir
    new_data_dir=$(_gum_input "Data directory" --value "$cur_data_dir")
    [[ -z "$new_data_dir" ]] && new_data_dir="$cur_data_dir"
    echo ""

    echo -e "  ${BOLD}editor${RESET} — Editor for opening plan.md files"
    echo -e "  ${DIM}Examples: \"code\", \"nvim\", \"open -a Obsidian\"${RESET}"
    if [[ -n "$cur_editor" ]]; then
        echo -e "  ${DIM}Current: ${cur_editor}${RESET}"
    else
        echo -e "  ${DIM}Current: (auto-detect from \$EDITOR)${RESET}"
    fi
    local new_editor
    new_editor=$(_gum_input "Editor command" --value "$cur_editor")
    echo ""

    echo -e "  ${BOLD}linear_org${RESET} — Linear organization slug (for ticket URLs)"
    if [[ -n "$cur_linear_org" ]]; then
        echo -e "  ${DIM}Current: ${cur_linear_org}${RESET}"
    else
        echo -e "  ${DIM}Current: (disabled)${RESET}"
    fi
    local new_linear_org
    new_linear_org=$(_gum_input "Linear org slug (leave empty to skip)" --value "$cur_linear_org")
    echo ""

    echo -e "  ${BOLD}worktree_dir${RESET} — Worktree directory relative to repo root"
    echo -e "  ${DIM}Current: ${cur_worktree_dir}${RESET}"
    local new_worktree_dir
    new_worktree_dir=$(_gum_input "Worktree directory" --value "$cur_worktree_dir")
    [[ -z "$new_worktree_dir" ]] && new_worktree_dir="$cur_worktree_dir"
    echo ""

    echo -e "  ${BOLD}branch_prefix${RESET} — Prefix for auto-created branches"
    echo -e "  ${DIM}Current: ${cur_branch_prefix}${RESET}"
    local new_branch_prefix
    new_branch_prefix=$(_gum_input "Branch prefix" --value "$cur_branch_prefix")
    [[ -z "$new_branch_prefix" ]] && new_branch_prefix="$cur_branch_prefix"
    echo ""

    # Write settings
    mkdir -p "$settings_dir"
    cat > "$settings_file" <<ENDJSON
{
  "data_dir": "${new_data_dir}",
  "repo": "",
  "editor": "${new_editor}",
  "linear_org": "${new_linear_org}",
  "worktree_dir": "${new_worktree_dir}",
  "branch_prefix": "${new_branch_prefix}"
}
ENDJSON

    echo -e "${GREEN}${SYM_CHECK}${RESET} Settings saved to ${DIM}${settings_file}${RESET}"

    # Create data directory
    local expanded_data_dir="${new_data_dir/#\~/$HOME}"
    if [[ ! -d "$expanded_data_dir" ]]; then
        mkdir -p "$expanded_data_dir/todo"
        echo '[]' > "$expanded_data_dir/todos.json"
        echo -e "${GREEN}${SYM_CHECK}${RESET} Created data directory at ${DIM}${new_data_dir}${RESET}"
    else
        echo -e "${DIM}Data directory already exists at ${new_data_dir}${RESET}"
    fi

    echo ""
    echo -e "  ${DIM}Run ${CYAN}td${RESET} ${DIM}to get started.${RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# td settings — Print the settings file
# ---------------------------------------------------------------------------

cmd_settings() {
    if [[ -f "$TODO_SETTINGS" ]]; then
        echo -e "${DIM}${TODO_SETTINGS}${RESET}"
        echo ""
        cat "$TODO_SETTINGS"
    else
        echo -e "${RED}No settings file found.${RESET}" >&2
        echo -e "Run ${CYAN}td init${RESET} to create one." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# td help
# ---------------------------------------------------------------------------

cmd_help() {
    echo ""
    echo -e "${CYAN}  ▄▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄${RESET}"
    echo -e "${CYAN}    █    █   █ █    █ █   █${RESET}"
    echo -e "${CYAN}    █    █   █ █    █ █   █${RESET}"
    echo -e "${CYAN}    █    █▄▄▄█ █▄▄▄▀  █▄▄▄█${RESET}"
    echo ""
    echo -e "  ${DIM}Minimal task manager for Claude Code${RESET}  ${DIM}v${TODO_VERSION}${RESET}"
    echo -e "  ${DIM}Handles plan injections, Claude sessions and worktree management.${RESET}"
    echo -e "  ${DIM}All commands work non-interactively for AI agents.${RESET}"
    echo ""
    echo -e "  ${DIM}$(printf '%.0s─' {1..54})${RESET}"
    echo ""
    echo -e "  ${BOLD}Interactive${RESET}"
    echo ""
    echo -e "  ${CYAN}td${RESET}                              Open interactive app"
    echo -e "  ${CYAN}td do${RESET} ${DIM}\"title\"${RESET}                  Create todo & start Claude immediately"
    echo -e "  ${CYAN}td find${RESET} ${DIM}[query]${RESET}                 Find Claude session → create todo & resume"
    echo -e "  ${CYAN}td edit${RESET} ${DIM}[id]${RESET}                    Open plan in editor"
    echo -e "  ${CYAN}td link${RESET} ${DIM}[id]${RESET}                   Link Linear/GitHub/plan"
    echo -e "  ${CYAN}td open${RESET}                         Open links in browser"
    echo -e "  ${CYAN}td browse${RESET}                       Open notes dir in editor"
    echo ""
    echo -e "  ${BOLD}Non-interactive${RESET} ${DIM}(AI-friendly)${RESET}"
    echo ""
    echo -e "  ${CYAN}td new${RESET} ${DIM}[-b] \"title\"${RESET}              Create a new todo (-b for backlog)"
    echo -e "  ${CYAN}td done${RESET} ${DIM}<id>${RESET}                    Mark as done"
    echo -e "  ${CYAN}td try${RESET} ${DIM}[id]${RESET}                     Apply worktree diff to try branch"
    echo -e "  ${CYAN}td bump${RESET} ${DIM}[id]${RESET}                    Toggle between TODO and backlog"
    echo -e "  ${CYAN}td rename${RESET} ${DIM}<id> \"title\"${RESET}          Rename a todo"
    echo -e "  ${CYAN}td delete${RESET} ${DIM}<id> [--force]${RESET}       Delete todo and all data"
    echo -e "  ${CYAN}td note${RESET} ${DIM}<id> \"text\"${RESET}             Append to plan"
    echo -e "  ${CYAN}td get${RESET} ${DIM}<id>${RESET}                     Print todo as JSON"
    echo -e "  ${CYAN}td show${RESET} ${DIM}<id>${RESET}                    Print plan path"
    echo -e "  ${CYAN}td split${RESET} ${DIM}<id> \"title\"${RESET}           Create subtask"
    echo -e "  ${CYAN}td link${RESET} ${DIM}<id> <url|path>${RESET}        Link Linear/GitHub/plan"
    echo -e "  ${CYAN}td list${RESET}                         List active todos"
    echo -e "  ${CYAN}td archive${RESET}                      Show completed todos"
    echo -e "  ${CYAN}td sync${RESET} ${DIM}[-n]${RESET}                     Two-way sync: create/remove todos & dirs"
    echo -e "  ${CYAN}td version${RESET}                      Print version"
    echo -e "  ${CYAN}td update${RESET}                       Update to latest version"
    echo ""
    echo -e "  ${DIM}$(printf '%.0s─' {1..54})${RESET}"
    echo ""
    echo -e "  ${BOLD}Hooks${RESET}"
    echo ""
    echo -e "  ${DIM}PreCompact — saves conversation to plan before context compaction${RESET}"
    echo -e "  ${DIM}Configure in ~/.claude/settings.json${RESET}"
    echo ""
    echo -e "  ${DIM}$(printf '%.0s─' {1..54})${RESET}"
    echo ""
    echo -e "  ${CYAN}td init${RESET}                        Configure settings interactively"
    echo -e "  ${CYAN}td settings${RESET}                    Print settings file"
    echo ""
    echo -e "  ${DIM}$(printf '%.0s─' {1..54})${RESET}"
    echo ""
    echo -e "  ${BOLD}Config${RESET}  ${DIM}~/.config/claude-todo/settings.json${RESET}"
    echo -e "  ${BOLD}Data${RESET}    ${DIM}~/td/${RESET}"
    echo ""
}
