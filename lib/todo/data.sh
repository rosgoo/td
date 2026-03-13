#!/usr/bin/env bash
# data.sh — JSON data access and todo CRUD helpers.
#
# All functions here operate on the flat JSON array in $TODOS_FILE.
# They handle reading, writing, querying, and ID generation — but
# no UI, git, or session logic.

# --- Setup ------------------------------------------------------------------

_ensure_setup() {
    mkdir -p "$DATA_DIR" "$NOTES_DIR"
    if [[ ! -f "$TODOS_FILE" ]]; then
        echo '[]' > "$TODOS_FILE"
    fi
}

# --- Dependency checks ------------------------------------------------------

_check_jq() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error:${RESET} jq is not installed. brew install jq" >&2
        exit 1
    fi
}

_check_gum() {
    if ! command -v gum &>/dev/null; then
        echo -e "${RED}Error:${RESET} gum is not installed. brew install gum" >&2
        exit 1
    fi
}

# --- ID helpers -------------------------------------------------------------

_generate_id() {
    # Produces a unique ID like "1773329209-79908c" (epoch-random hex).
    echo "$(date +%s)-$(openssl rand -hex 3)"
}

_slugify() {
    # Lowercases, strips non-alphanumeric chars, collapses dashes, truncates to 40 chars.
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40
}

_notes_folder_name() {
    # Returns a human-readable folder name for use in NOTES_DIR.
    # Uses just the slug, with a -2, -3 suffix if there's a collision.
    local id="$1" title="$2"
    local slug
    slug=$(_slugify "$title")
    [[ -z "$slug" ]] && slug="untitled"

    local candidate="$slug"
    local n=2
    while [[ -d "${NOTES_DIR}/${candidate}" ]]; do
        # Check if this folder belongs to the same todo (already correct)
        local existing_plan="${NOTES_DIR}/${candidate}/plan.md"
        if [[ -f "$existing_plan" ]]; then
            local existing_id
            existing_id=$(_read_todos | jq -r --arg np "${existing_plan}" '.[] | select(.notes_path == $np) | .id')
            [[ "$existing_id" == "$id" ]] && break
        fi
        candidate="${slug}-${n}"
        ((n++))
    done
    echo "$candidate"
}

_resolve_id() {
    # Resolve a todo by exact ID or unique prefix. Returns the full ID on stdout.
    # Exits 1 if no unique match is found.
    local input="$1"
    if [[ -z "$input" ]]; then
        return 1
    fi

    # Try exact match first
    local match
    match=$(_read_todos | jq -r --arg id "$input" '[.[] | select(.id == $id)] | .[0].id // empty')
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    # Try prefix match (must be unique)
    match=$(_read_todos | jq -r --arg prefix "$input" '[.[] | select(.id | startswith($prefix))] | if length == 1 then .[0].id else empty end')
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    # Try suffix match (for short IDs like "0f1c27")
    match=$(_read_todos | jq -r --arg suffix "$input" '[.[] | select(.id | endswith($suffix))] | if length == 1 then .[0].id else empty end')
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    echo -e "${RED}Error:${RESET} No unique todo found for '${input}'." >&2
    return 1
}

# --- Read/write -------------------------------------------------------------

_read_todos() {
    cat "$TODOS_FILE"
}

_write_todos() {
    local json="$1"
    echo "$json" > "$TODOS_FILE"
}

# --- Queries ----------------------------------------------------------------

_get_todo() {
    # Returns a single todo object as JSON, or empty string if not found.
    local id="$1"
    _read_todos | jq -r --arg id "$id" '.[] | select(.id == $id)'
}

_active_todos() {
    _read_todos | jq -r '[.[] | select(.status == "active")] | sort_by(.created_at) | reverse'
}

_done_todos() {
    _read_todos | jq -r '[.[] | select(.status == "done")] | sort_by(.created_at) | reverse'
}

# --- Notes ------------------------------------------------------------------

_ensure_notes() {
    # Creates plan.md for a todo if it doesn't exist yet. Returns the file path.
    local id="$1"
    local title="$2"
    local notes_path="${NOTES_DIR}/$(_notes_folder_name "$id" "$title")"

    if [[ ! -f "${notes_path}/plan.md" ]]; then
        mkdir -p "$notes_path"
        cat > "${notes_path}/plan.md" << EOF
# ${title}

Created: $(date '+%Y-%m-%d %H:%M')

## Plan

EOF
        # Persist the notes_path back into the todo record
        local updated
        updated=$(_read_todos | jq --arg id "$id" --arg np "${notes_path}/plan.md" \
            'map(if .id == $id then .notes_path = $np else . end)')
        _write_todos "$updated"
    fi

    echo "${notes_path}/plan.md"
}
