#!/usr/bin/env bash
# git.sh — Git repository, URL, and worktree path helpers.
#
# Pure utility functions for git operations: repo validation, URL construction
# for GitHub/Linear, worktree validation, and extracting identifiers from URLs.

# --- Repo validation --------------------------------------------------------

_require_repo() {
    if [[ -z "$REPO_ROOT" ]]; then
        echo -e "${RED}Error:${RESET} Not in a git repository. Run from a repo or set TODO_REPO." >&2
        exit 1
    fi
}

# --- Path helpers -----------------------------------------------------------

_worktree_dir() {
    echo "${REPO_ROOT}/${WORKTREE_DIR}"
}

# --- URL construction -------------------------------------------------------

_github_repo_url() {
    # Converts the origin remote URL to an HTTPS GitHub URL.
    local remote_url
    remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
    remote_url="${remote_url%.git}"
    remote_url="${remote_url/git@github.com:/https://github.com/}"
    echo "$remote_url"
}

_github_branch_url() {
    # Returns a GitHub URL for a branch. If the input is already an HTTP URL
    # (e.g. a PR link stored as branch), returns it as-is.
    local branch="$1"
    if [[ "$branch" == http* ]]; then
        echo "$branch"
        return
    fi
    local repo_url
    repo_url=$(_github_repo_url)
    if [[ -n "$repo_url" && -n "$branch" ]]; then
        echo "${repo_url}/tree/${branch}"
    fi
}

_linear_ticket_url() {
    # Converts a ticket ID like "CORE-12207" to a Linear app URL.
    local ticket="$1"
    if [[ -n "$ticket" && -n "$LINEAR_ORG" ]]; then
        local lower
        lower=$(echo "$ticket" | tr '[:upper:]' '[:lower:]')
        echo "https://linear.app/${LINEAR_ORG}/issue/${lower}"
    fi
}

# --- Worktree validation ---------------------------------------------------

_validate_worktree() {
    # Checks that a worktree path exists and is a valid git working tree.
    local worktree_path="$1"
    if [[ ! -d "$worktree_path" ]]; then
        return 1
    fi
    git -C "$worktree_path" rev-parse --git-dir &>/dev/null 2>&1
}

# --- URL parsing (extract IDs from pasted URLs) ----------------------------

_extract_linear_ticket() {
    # Extracts a ticket ID from a Linear URL or raw ID.
    # e.g. "https://linear.app/maybern/issue/core-12207/some-title" -> "CORE-12207"
    local input="$1"
    if [[ "$input" == *"linear.app"* ]]; then
        echo "$input" | sed -n 's|.*/issue/\([^/]*\).*|\1|p' | tr '[:lower:]' '[:upper:]'
    else
        echo "$input" | tr '[:lower:]' '[:upper:]'
    fi
}

_extract_github_branch() {
    # Extracts a branch name from a GitHub URL or returns the raw input.
    # PR URLs return empty — the caller should store them as github_pr instead.
    local input="$1"
    if [[ "$input" == *"github.com"*"/tree/"* ]]; then
        echo "$input" | sed -n 's|.*/tree/\(.*\)|\1|p'
    elif [[ "$input" == *"github.com"*"/pull/"* ]]; then
        echo ""
    else
        echo "$input"
    fi
}
