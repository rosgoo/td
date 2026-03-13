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
    #
    # Args:
    #   $1 — show_done: "true" (default) or "false"
    #   $2 — group_filter: "todo", "backlog", or "" (all groups, default)

    local show_done="${1:-true}"
    local group_filter="${2:-}"
    local all_todos
    if [[ "$show_done" == "true" ]]; then
        all_todos=$(_read_todos | jq -r --arg gf "$group_filter" '
            [.[] | select(
                if $gf == "" then true
                elif $gf == "todo" then (.group // "todo") == "todo"
                elif $gf == "backlog" then (.group // "todo") == "backlog"
                else true end
            )] | sort_by(.created_at) | reverse')
    else
        all_todos=$(_read_todos | jq -r --arg gf "$group_filter" '
            [.[] | select(.status != "done") | select(
                if $gf == "" then true
                elif $gf == "todo" then (.group // "todo") == "todo"
                elif $gf == "backlog" then (.group // "todo") == "backlog"
                else true end
            )] | sort_by(.created_at) | reverse')
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
    #   1. Builds a tree: root todos at top, descendants nested below at any depth.
    #   2. For each todo, formats fixed-width columns with ANSI escape codes.
    #   3. Subtasks get "└─" indent scaled by depth, and de-duplicate branch/dir
    #      when they match their root ancestor.
    echo "$all_todos" | jq -r --arg now "$now_epoch" --arg today "$today_epoch" --arg yesterday "$yesterday_epoch" --arg gf "$group_filter" '
        # Sort key: last_opened_at if set, else created_at
        def sort_key: (.last_opened_at // .created_at);

        . as $all |

        # Walk up parent_id chain to find depth (0 = root)
        def depth:
            . as $id |
            if $id == "" then 0
            else
                ([$all[] | select(.id == $id)] | .[0]) as $todo |
                if $todo == null then 0
                else 1 + (($todo.parent_id // "") | depth)
                end
            end;

        # Walk up to find root ancestor (the top-level parent)
        def root_ancestor:
            . as $todo |
            if ($todo.parent_id // "") == "" then $todo
            else
                ([$all[] | select(.id == $todo.parent_id)] | .[0]) as $par |
                if $par == null then $todo else $par | root_ancestor end
            end;

        # Recursively emit a todo followed by its children (active first, then done)
        def emit_tree:
            . as $node |
            $node,
            ( [ $all[] | select(.parent_id == $node.id and .status == "active") ] | sort_by(.created_at) | .[] | emit_tree ),
            ( [ $all[] | select(.parent_id == $node.id and .status == "done") ] | sort_by(.created_at) | .[] | emit_tree );

        def is_root: (.parent_id // "") == "";

        # Build ordered list: active roots (with descendants), then done roots (with descendants)
        [
            ( [ $all[] | select(.status == "active" and is_root) ] | sort_by(sort_key) | reverse | .[] | emit_tree ),
            ( [ $all[] | select(.status == "done" and is_root) ] | sort_by(sort_key) | reverse | .[] | emit_tree )
        ][] |

        (.id) as $id |
        (.title) as $title |
        (.status // "active") as $status |
        (.group // "todo") as $group |
        (.branch // "") as $branch |
        (.worktree_path // "") as $wt |
        (.linear_ticket // "") as $ticket |
        (.session_id // "") as $session |
        (.parent_id // "") as $pid |
        ($pid | depth) as $depth |
        ($depth > 0) as $is_subtask |

        # Dedup: hide branch/dir when same as root ancestor
        (if $is_subtask then
            (. | root_ancestor) as $root |
            if $root != null and $branch == ($root.branch // "") then "" else $branch end
        else $branch end) as $display_branch |
        (if $is_subtask then
            (. | root_ancestor) as $root |
            if $root != null and $wt == ($root.worktree_path // "") then "" else $wt end
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

        # Project dir: last component of worktree_path
        (if $display_wt != "" then ($display_wt | split("/") | .[-1]) else "" end) as $dir |

        # Indent: 3 spaces per depth level, then "└─ " for subtasks
        (if $is_subtask then
            (" " * (($depth - 1) * 3)) + "└─ "
        else "" end) as $indent |
        # Title width shrinks with indent (3 chars per depth level)
        (80 - ($depth * 3)) as $tw |

        # Fixed-width columns: age(10)  icon(2) [indent] title  dir(16)  branch(30)
        ($age | .[:10] | . + (" " * (10 - length))) as $age_col |
        (if $ticket != "" then ($ticket + " " + $title) else $title end) as $full_title |
        (if $tw > 0 then ($full_title | .[:$tw] | . + (" " * ([($tw - length), 0] | max))) else "" end) as $title_col |
        ($dir | .[:16] | . + (" " * (16 - length))) as $dir_col |
        ($display_branch | .[:30] | . + (" " * (30 - length))) as $branch_col |

        if $status == "done" then
            "\($id)\t\($wt)\t\($branch)\t\u001b[2;9m\($age_col)  \u001b[0;32m✓\u001b[2;9m \($indent)\($title_col)  \($dir_col)  \($branch_col)\u001b[0m"
        else
            (if $group == "backlog" then
                (if $session != "" then "\u001b[2m○\u001b[0m " else "  " end)
            else
                (if $session != "" then "\u001b[0;32m◉\u001b[0m " else "  " end)
            end) as $icon |
            (if $ticket != "" then
                (if $tw > 0 then
                    ($tw - ($ticket | length) - 1) as $ttw |
                    "\u001b[0;35m\($ticket)\u001b[0m " + (($title | .[:$ttw]) as $t | $t + (" " * ([($ttw - ($t | length)), 0] | max)))
                else "" end)
            else
                $title_col
            end) as $colored_title |
            "\($id)\t\($wt)\t\($branch)\t\u001b[2m\($age_col)\u001b[0m  \($icon)\($indent)\($colored_title)  \u001b[2m\($dir_col)\u001b[0m  \u001b[0;36m\($branch_col)\u001b[0m"
        end
    '
}
