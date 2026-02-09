#!/bin/bash
#
# Bashobot Command Approval and Whitelist
#

ensure_command_whitelist_file() {
    local whitelist_dir
    whitelist_dir=$(dirname "$BASHOBOT_CMD_WHITELIST_FILE")
    mkdir -p "$whitelist_dir"
    if [[ ! -f "$BASHOBOT_CMD_WHITELIST_FILE" ]]; then
        touch "$BASHOBOT_CMD_WHITELIST_FILE"
        chmod 600 "$BASHOBOT_CMD_WHITELIST_FILE" 2>/dev/null || true
    fi
}

# Extract the primary command name from a shell command string
extract_command_name() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        return 1
    fi

    # Strip leading whitespace
    raw=$(echo "$raw" | sed 's/^[[:space:]]*//')

    # Use awk to skip env assignments and sudo
    echo "$raw" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=.*/) { next }
            if ($i == "sudo") { continue }
            print $i; exit
        }
    }'
}

is_command_whitelisted() {
    local cmd="$1"
    ensure_command_whitelist_file
    grep -Fxq "$cmd" "$BASHOBOT_CMD_WHITELIST_FILE"
}

add_command_to_whitelist() {
    local cmd="$1"
    ensure_command_whitelist_file
    if ! grep -Fxq "$cmd" "$BASHOBOT_CMD_WHITELIST_FILE"; then
        echo "$cmd" >> "$BASHOBOT_CMD_WHITELIST_FILE"
    fi
}

# Sanitize id for filesystem usage
sanitize_id() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

approval_set_pending() {
    local session_id="$1"
    local cmd="$2"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    mkdir -p "$BASHOBOT_CMD_APPROVAL_DIR"
    printf '%s' "$cmd" > "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
}

approval_get_pending() {
    local session_id="$1"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    if [[ -f "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id" ]]; then
        cat "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
    fi
}

approval_clear_pending() {
    local session_id="$1"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    rm -f "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
}
