#!/bin/bash
#
# Bashobot Interface: Telegram
#
# Required env: TELEGRAM_BOT_TOKEN
# Optional env: TELEGRAM_ALLOWED_USERS (comma-separated user IDs)
#

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
TELEGRAM_POLL_TIMEOUT=30
TELEGRAM_OFFSET_FILE="$CONFIG_DIR/telegram_offset"

# Validate configuration
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "Error: TELEGRAM_BOT_TOKEN not set in config" >&2
    exit 1
fi

# Check if user is allowed
_is_user_allowed() {
    local user_id="$1"
    
    # If no allowlist, allow everyone (not recommended for production)
    if [[ -z "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
        return 0
    fi
    
    # Check if user_id is in the comma-separated list
    echo ",$TELEGRAM_ALLOWED_USERS," | grep -q ",$user_id,"
}

# Get updates from Telegram
_telegram_get_updates() {
    local offset="${1:-0}"
    
    curl -s -X POST "${TELEGRAM_API}/getUpdates" \
        -H "Content-Type: application/json" \
        -d "{\"offset\": $offset, \"timeout\": $TELEGRAM_POLL_TIMEOUT}" \
        --max-time $((TELEGRAM_POLL_TIMEOUT + 5))
}

# Send message to Telegram
_telegram_send_message() {
    local chat_id="$1"
    local text="$2"
    
    # Telegram has a 4096 character limit, split if needed
    local max_len=4000
    
    while [[ ${#text} -gt 0 ]]; do
        local chunk="${text:0:$max_len}"
        text="${text:$max_len}"
        
        # Escape for JSON
        local escaped_chunk
        escaped_chunk=$(echo -n "$chunk" | jq -Rs '.')
        
        local result
        result=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": $chat_id, \"text\": $escaped_chunk}" \
            --max-time 10)
        local ok
        ok=$(echo "$result" | jq -r '.ok // false')
        if [[ "$ok" != "true" ]]; then
            log_error "event=telegram_send_failed payload=$result"
        else
            log_info "event=telegram_send_ok chat_id=$chat_id bytes=${#chunk}"
        fi
    done
}

# Send typing indicator
_telegram_send_typing() {
    local chat_id="$1"
    
    curl -s -X POST "${TELEGRAM_API}/sendChatAction" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": $chat_id, \"action\": \"typing\"}" \
        --max-time 5 > /dev/null
}

# Get stored offset
_get_offset() {
    if [[ -f "$TELEGRAM_OFFSET_FILE" ]]; then
        cat "$TELEGRAM_OFFSET_FILE"
    else
        echo "0"
    fi
}

# Save offset
_save_offset() {
    echo "$1" > "$TELEGRAM_OFFSET_FILE"
}

# Process a single update
_process_update() {
    local update="$1"
    
    local update_id chat_id user_id username text
    
    update_id=$(echo "$update" | jq -r '.update_id')
    chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
    user_id=$(echo "$update" | jq -r '.message.from.id // empty')
    username=$(echo "$update" | jq -r '.message.from.username // .message.from.first_name // "unknown"')
    text=$(echo "$update" | jq -r '.message.text // empty')
    
    # Save offset immediately (before processing)
    _save_offset $((update_id + 1))
    
    # Skip if no text message
    [[ -z "$text" ]] && return 0
    [[ -z "$chat_id" ]] && return 0
    
    # Check user authorization
    if ! _is_user_allowed "$user_id"; then
        log_info "event=telegram_unauthorized user_id=$user_id username=$username"
        _telegram_send_message "$chat_id" "Sorry, you are not authorized to use this bot."
        return 0
    fi
    
    log_info "event=telegram_message user_id=$user_id username=$username preview=${text:0:50}"
    
    # Send typing indicator
    _telegram_send_typing "$chat_id"
    
    # Use chat_id as session_id for conversation persistence
    local session_id="telegram_${chat_id}"
    
    # Enqueue message to daemon; daemon will reply via interface_send
    enqueue_message "$text" "$session_id" "telegram"
    
    log_info "event=telegram_queued user_id=$user_id username=$username"
}

# Start interface - called by daemon
interface_start() {
    log_info "Starting Telegram interface..."
    
    # Verify bot token works
    local me
    me=$(curl -s "${TELEGRAM_API}/getMe")
    local bot_name
    bot_name=$(echo "$me" | jq -r '.result.username // empty')
    
    if [[ -z "$bot_name" ]]; then
        log_error "Failed to connect to Telegram: $me"
        echo "Error: Invalid Telegram bot token" >&2
        return 1
    fi
    
    log_info "Connected as @$bot_name"
    
    while true; do
        local offset
        offset=$(_get_offset)
        
        local updates
        updates=$(_telegram_get_updates "$offset")
        
        # Check for error
        local ok
        ok=$(echo "$updates" | jq -r '.ok // false')
        if [[ "$ok" != "true" ]]; then
            log_error "event=telegram_api_error payload=$updates"
            sleep 5
            continue
        fi
        
        # Get number of updates
        local count
        count=$(echo "$updates" | jq '.result | length')
        
        # Process each update sequentially (no subshell)
        local i=0
        while [[ $i -lt $count ]]; do
            local update
            update=$(echo "$updates" | jq -c ".result[$i]")
            _process_update "$update"
            ((i++))
        done
        
        # Small delay only if no updates (long polling already waits)
        [[ $count -eq 0 ]] && sleep 1
    done
}

# Send message via interface - called when pipe message has telegram source
interface_send() {
    local session_id="$1"
    local message="$2"
    
    # Extract chat_id from session_id (telegram_CHATID)
    local chat_id="${session_id#telegram_}"
    
    if [[ "$chat_id" =~ ^[0-9-]+$ ]]; then
        _telegram_send_message "$chat_id" "$message"
    fi
}

# Interface info
interface_info() {
    echo "Interface: Telegram"
    echo "Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
}
