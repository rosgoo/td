#!/usr/bin/env bash
# ui.sh — Terminal UI helpers: gum wrappers, fzf picker, and display formatting.
#
# These functions handle all interactive terminal output — the fzf todo picker,
# gum prompts, and the formatted line rendering used in the picker.

# --- Dependency checks ------------------------------------------------------

_check_fzf() {
    if ! command -v fzf &>/dev/null; then
        echo -e "${RED}Error:${RESET} fzf is not installed. See https://github.com/junegunn/fzf#installation" >&2
        exit 1
    fi
}

# --- Gum wrappers (consistent styling) -------------------------------------

_gum_choose() {
    # Usage: _gum_choose "header" "option1" "option2" ...
    local header="$1"; shift
    gum choose --header "$header" --cursor "› " --cursor.foreground="4" --header.foreground="8" "$@"
}

_gum_confirm() {
    # Usage: _gum_confirm "prompt" [--default]
    gum confirm --prompt.foreground="8" "$@"
}

_gum_input() {
    # Usage: _gum_input "placeholder"
    gum input --placeholder "$1" --cursor.foreground="4" --prompt "› " --prompt.foreground="4"
}

# --- fzf picker -------------------------------------------------------------

_pick_todo() {
    # Shows an fzf picker of active todos. Returns the selected todo's ID on stdout.
    local header="${1:-Select a todo}"
    local prompt="${2:-❯ }"
    _check_fzf

    local fzf_lines
    fzf_lines=$(_format_fzf_lines)

    if [[ -z "$fzf_lines" ]]; then
        echo -e "${YELLOW}No active todos.${RESET}" >&2
        return 1
    fi

    local result
    result=$(echo -e "$fzf_lines" | fzf \
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
        --prompt="$prompt" \
    ) || true

    if [[ -z "$result" ]]; then
        return 1
    fi

    echo "$result" | cut -f1
}

# --- Line formatting for fzf -----------------------------------------------

_format_fzf_lines() {
    # Renders all todos as tab-delimited, ANSI-colored lines for fzf.
    #
    # Each line: ID\tworktree\tbranch\t<visible columns>
    # fzf uses --with-nth=4.. to display only the visible part.
    #
    # Columns: age(10) icon(2) [indent] title(77-80) dir(16) branch(30)
    #
    # Sorting: active parents first (most recently opened), with their subtasks
    # nested below. Done todos follow. Subtasks de-duplicate branch/dir when
    # they match their parent.

    local show_done="${1:-true}"
    local all_todos
    if [[ "$show_done" == "true" ]]; then
        all_todos=$(_read_todos | jq -r 'sort_by(.created_at) | reverse')
    else
        all_todos=$(_read_todos | jq -r '[.[] | select(.status != "done")] | sort_by(.created_at) | reverse')
    fi
    local count
    count=$(echo "$all_todos" | jq 'length')

    if (( count == 0 )); then
        return
    fi

    # Pre-compute date boundaries for the "age" column
    local now_epoch today_epoch yesterday_epoch
    now_epoch=$(date +%s)
    today_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s)
    yesterday_epoch=$((today_epoch - 86400))

    # Single jq call renders every line. The jq program:
    #   1. Groups todos: active parents (sorted by last_opened_at), each followed
    #      by its subtasks, then done parents with their subtasks.
    #   2. For each todo, formats fixed-width columns with ANSI escape codes.
    #   3. Subtasks get a "└─" indent and de-duplicate branch/dir from parent.
    echo "$all_todos" | jq -r --arg now "$now_epoch" --arg today "$today_epoch" --arg yesterday "$yesterday_epoch" '
        # Sort key: last_opened_at if set, else created_at
        def sort_key: (.last_opened_at // .created_at);
        # Order: active parents (with subtasks beneath each), then done parents (with subtasks)
        . as $all |
        def is_child: (.parent_id // "") != "";
        [
            ( [ $all[] | select(.status == "active" and (is_child | not)) ] | sort_by(sort_key) | reverse | .[] as $p |
                $p,
                ( [ $all[] | select(.parent_id == $p.id and .status == "active") ] | sort_by(.created_at) | .[] ),
                ( [ $all[] | select(.parent_id == $p.id and .status == "done") ] | sort_by(.created_at) | .[] )
            ),
            ( [ $all[] | select(.status == "done" and (is_child | not)) ] | sort_by(sort_key) | reverse | .[] as $p |
                $p,
                ( [ $all[] | select(.parent_id == $p.id) ] | sort_by(.created_at) | .[] )
            )
        ][] |
        (.id) as $id |
        (.title) as $title |
        (.status // "active") as $status |
        (.branch // "") as $branch |
        (.worktree_path // "") as $wt |
        (.linear_ticket // "") as $ticket |
        (.session_id // "") as $session |
        (.parent_id // "") as $pid |
        ($pid != "") as $is_subtask |
        # Dedup: hide branch/dir for subtasks when same as parent
        (if $is_subtask then
            ([$all[] | select(.id == $pid)] | .[0]) as $par |
            if $par != null and $branch == ($par.branch // "") then "" else $branch end
        else $branch end) as $display_branch |
        (if $is_subtask then
            ([$all[] | select(.id == $pid)] | .[0]) as $par |
            if $par != null and $wt == ($par.worktree_path // "") then "" else $wt end
        else $wt end) as $display_wt |
        (
            (.created_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $ts |
            if $ts >= ($today | tonumber) then "today"
            elif $ts >= ($yesterday | tonumber) then "yesterday"
            else (
                (($now | tonumber) - $ts) as $diff |
                if $diff < 604800 then "\($diff / 86400 | floor)d ago"
                else (.created_at | split("T")[0])
                end
            )
            end
        ) as $age |
        # Project dir: last component of worktree_path (like mb cs)
        (if $display_wt != "" then ($display_wt | split("/") | .[-1]) else "" end) as $dir |
        # Subtask indent prefix
        (if $is_subtask then "└─ " else "" end) as $indent |
        (if $is_subtask then 77 else 80 end) as $tw |
        # Fixed-width columns: age(10)  icon(2) [indent] title(77-80)  dir(16)  branch(30)
        ($age | .[:10] | . + (" " * (10 - length))) as $age_col |
        (if $ticket != "" then ($ticket + " " + $title) else $title end) as $full_title |
        ($full_title | .[:$tw] | . + (" " * ($tw - length))) as $title_col |
        ($dir | .[:16] | . + (" " * (16 - length))) as $dir_col |
        ($display_branch | .[:30] | . + (" " * (30 - length))) as $branch_col |
        if $status == "done" then
            "\($id)\t\($wt)\t\($branch)\t\u001b[2;9m\($age_col)  \u001b[0;32m✓\u001b[2;9m \($indent)\($title_col)  \($dir_col)  \($branch_col)\u001b[0m"
        else
            (if $session != "" then "\u001b[0;32m◉\u001b[0m " else "  " end) as $icon |
            (if $ticket != "" then
                "\u001b[0;35m\($ticket)\u001b[0m " + (($title | .[:$tw - ($ticket | length) - 1]) as $t | $t + (" " * ($tw - ($ticket | length) - 1 - ($t | length))))
            else
                $title_col
            end) as $colored_title |
            "\($id)\t\($wt)\t\($branch)\t\u001b[2m\($age_col)\u001b[0m  \($icon)\($indent)\($colored_title)  \u001b[2m\($dir_col)\u001b[0m  \u001b[0;36m\($branch_col)\u001b[0m"
        end
    '
}
