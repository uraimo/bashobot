#!/bin/bash
#
# Bashobot Core
#
# Core runtime, logging, and daemon loop helpers.
#

# ============================================================================
# Initialization
# ============================================================================

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$SESSIONS_DIR" "$PIPE_DIR"
    config_load
}

init_pipes() {
    # Create named pipes if they don't exist
    [[ -p "$INPUT_PIPE" ]] || mkfifo "$INPUT_PIPE"
    [[ -p "$OUTPUT_PIPE" ]] || mkfifo "$OUTPUT_PIPE"
}

cleanup_pipes() {
    rm -f "$INPUT_PIPE" "$OUTPUT_PIPE"
}

# ============================================================================
# Logging
# ============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
    [[ "${VERBOSE:-0}" == "1" ]] && echo "[$level] $*" >&2 || true
}

log_info()  { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# ============================================================================
# Helpers
# ============================================================================

capture_output() {
    local tmp status
    tmp=$(mktemp)
    "$@" > "$tmp"
    status=$?
    cat "$tmp"
    rm -f "$tmp"
    return $status
}

# ============================================================================
# Provider Loading
# ============================================================================

load_provider() {
    local provider="$1"
    local provider_file="$BASHOBOT_DIR/providers/${provider}.sh"

    if [[ ! -f "$provider_file" ]]; then
        echo "Error: Provider '$provider' not found at $provider_file" >&2
        echo "Available providers:" >&2
        ls -1 "$BASHOBOT_DIR/providers/"*.sh 2>/dev/null | xargs -n1 basename | sed 's/.sh$//' >&2
        exit 1
    fi

    source "$provider_file"
    log_info "Loaded LLM provider: $provider"
}

load_interface() {
    local interface="$1"
    local interface_file="$BASHOBOT_DIR/interfaces/${interface}.sh"

    if [[ ! -f "$interface_file" ]]; then
        echo "Error: Interface '$interface' not found at $interface_file" >&2
        echo "Available interfaces:" >&2
        ls -1 "$BASHOBOT_DIR/interfaces/"*.sh 2>/dev/null | xargs -n1 basename | sed 's/.sh$//' >&2
        exit 1
    fi

    source "$interface_file"
    log_info "Loaded interface: $interface"
}

# ============================================================================
# Session Management
# ============================================================================

get_session_file() {
    local session_id="${1:-default}"
    echo "$SESSIONS_DIR/${session_id}.json"
}

get_session_llm_file() {
    local session_id="${1:-default}"
    echo "$SESSIONS_DIR/${session_id}.llm.json"
}

ensure_llm_log_file() {
    local session_id="$1"
    local llm_file
    llm_file=$(get_session_llm_file "$session_id")

    if [[ ! -f "$llm_file" ]]; then
        echo '{"llm_log":[]}' | jq '.' > "$llm_file"
    fi
}

init_session() {
    local session_id="${1:-default}"
    local session_file
    session_file=$(get_session_file "$session_id")
    
    if [[ ! -f "$session_file" ]]; then
        echo '{"messages":[]}' | jq '.' > "$session_file"
    fi

    ensure_llm_log_file "$session_id"
}

append_message() {
    local session_id="$1"
    local role="$2"
    local content="$3"
    local llm_file
    llm_file=$(get_session_llm_file "$session_id")
    ensure_llm_log_file "$session_id"
    json_append_message "$session_file" "$role" "$content"
}

get_messages() {
    local session_id="$1"
    local session_file
    session_file=$(get_session_file "$session_id")
    json_get_messages "$session_file"
}

append_llm_log() {
    local session_id="$1"
    local request_messages="$2"
    local provider_request="$3"
    local provider_response="$4"
    local status="$5"
    local elapsed="$6"
    local source="$7"

    local session_file
    session_file=$(get_session_file "$session_id")

    local model_name="unknown"
    case "$LLM_PROVIDER" in
        gemini) model_name="${GEMINI_MODEL:-unknown}" ;;
        claude) model_name="${CLAUDE_MODEL:-unknown}" ;;
        openai) model_name="${OPENAI_MODEL:-unknown}" ;;
    esac

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local log_entry
    log_entry=$(jq -n \
        --arg ts "$ts" \
        --arg source "$source" \
        --arg provider "$LLM_PROVIDER" \
        --arg model "$model_name" \
        --argjson status "$status" \
        --argjson elapsed "$elapsed" \
        --argjson request_messages "$request_messages" \
        --arg provider_request "$provider_request" \
        --arg provider_response "$provider_response" \
        '{
            timestamp: $ts,
            source: $source,
            provider: $provider,
            model: $model,
            status: $status,
            elapsed_seconds: $elapsed,
            request_messages: $request_messages,
            provider_request: $provider_request,
            provider_response: $provider_response
        }')
    json_append_llm_log "$llm_file" "$log_entry"
}

# ============================================================================
# Core Agent Loop
# ============================================================================

process_message() {
    local session_id="$1"
    local user_message="$2"
    local source="${3:-cli}"  # cli, telegram, pipe

    CURRENT_SESSION_ID="$session_id"

    # Reload runtime overrides on each message (keeps /model changes)
    if [[ -f "$CONFIG_DIR/runtime.env" ]]; then
        source "$CONFIG_DIR/runtime.env"
    fi

    log_info "event=message_processing source=$source preview=${user_message:0:50}"

    # Check if it's a command
    if [[ "$user_message" == /* ]]; then
        local cmd_output
        cmd_output=$(capture_output process_command "$session_id" "$user_message")
        local cmd_status=$?

        if [[ $cmd_status -eq 0 ]]; then
            # Command handled, return output
            echo "$cmd_output"
            return 0
        fi
        # cmd_status == 1 means not a command, continue to LLM
    fi

    # Handle pending command approvals (non-slash input only)
    local pending_cmd
    pending_cmd=$(approval_get_pending "$session_id")
    if [[ -n "$pending_cmd" ]]; then
        local decision
        decision=$(echo "$user_message" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$decision" == "yes" ]]; then
            add_command_to_whitelist "$pending_cmd"
            approval_clear_pending "$session_id"
            echo "Approved command: $pending_cmd"
            return 0
        fi
        approval_clear_pending "$session_id"
        echo "Error: command denied: $pending_cmd"
        return 0
    fi

    # Add user message to session
    append_message "$session_id" "user" "$user_message"

    # Check if we need to summarize before calling LLM
    check_and_summarize "$session_id"

    # Get conversation history (includes summary if present)
    local messages
    messages=$(get_messages_for_llm "$session_id")

    # Inject relevant memory context if this is the first message in session
    local msg_count
    msg_count=$(echo "$messages" | jq 'length')
    if [[ $msg_count -le 2 ]]; then
        messages=$(inject_memory_context "$messages" "$user_message")
    fi

    # Call LLM provider (function defined in provider script)
    local response
    response=$(llm_run "$messages" "$session_id" "$source")
    local llm_status="${LLM_LAST_STATUS:-0}"

    if [[ $llm_status -ne 0 ]] || [[ -z "$response" ]]; then
        if [[ -n "$response" ]]; then
            log_error "LLM error (status=$llm_status): $response"
            response="$response"
        else
            response="Sorry, I encountered an error processing your message."
            log_error "LLM error (status=$llm_status) or empty response"
        fi
    fi

    # Add assistant response to session
    append_message "$session_id" "assistant" "$response"

    echo "$response"
}

llm_run() {
    local messages="$1"
    local session_id="$2"
    local source="$3"

    local response
    local llm_start llm_end llm_elapsed
    llm_start=$(date +%s)
    log_info "event=llm_request_start session=$session_id source=$source"
    log_info "event=llm_request_messages session=$session_id payload=$(echo "$messages" | jq -c '.')"
    set +e
    response=$(llm_chat "$messages")
    local llm_status=$?
    set -e

    local raw_meta="$response"
    local meta_text=""
    local meta_request=""
    local meta_response=""
    if echo "$raw_meta" | jq -e . >/dev/null 2>&1; then
        meta_text=$(echo "$raw_meta" | jq -r '.text // empty')
        meta_request=$(echo "$raw_meta" | jq -r '.request // empty')
        meta_response=$(echo "$raw_meta" | jq -r '.response // empty')
    else
        meta_text="$raw_meta"
    fi

    response="$meta_text"
    llm_end=$(date +%s)
    llm_elapsed=$((llm_end - llm_start))
    log_info "event=llm_response session=$session_id source=$source status=$llm_status elapsed=${llm_elapsed}s bytes=${#response}"
    if [[ -n "$meta_response" ]]; then
        log_info "event=llm_response_raw session=$session_id payload=$meta_response"
    else
        log_info "event=llm_response_raw session=$session_id payload=$raw_meta"
    fi

    append_llm_log "$session_id" "$messages" "$meta_request" "$meta_response" "$llm_status" "$llm_elapsed" "$source"
    LLM_LAST_STATUS="$llm_status"

    echo "$response"
}

dispatch_response() {
    local session_id="$1"
    local source="$2"
    local response="$3"

    if [[ "$source" == "pipe" ]] || [[ "$source" == "cli" ]]; then
        local encoded_response
        encoded_response=$(echo "$response" | base64)
        echo "${session_id}|${encoded_response}" > "$OUTPUT_PIPE"
    fi

    if [[ "$source" == "telegram" ]]; then
        log_info "event=interface_send session=$session_id source=$source"
        interface_send "$session_id" "$response"
    fi
}

handle_incoming_message() {
    local session_id="$1"
    local source="$2"
    local message="$3"

    [[ -z "$message" ]] && return 0
    log_info "event=message_received session=$session_id source=$source bytes=${#message}"

    init_session "$session_id"

    local response
    response=$(capture_output process_message "$session_id" "$message" "$source")

    dispatch_response "$session_id" "$source" "$response"
}

daemon_loop() {
    log_info "Starting Bashobot daemon..."
    log_info "LLM Provider: $LLM_PROVIDER"
    log_info "Interface: $INTERFACE"
    log_info "Heartbeat interval: ${HEARTBEAT_INTERVAL}s"

    # Save PID
    echo $$ > "$PID_FILE"

    # Initialize pipes
    init_pipes

    # Cleanup function - kill entire process group
    cleanup_daemon() {
        log_info "Shutting down..."
        cleanup_pipes
        rm -f "$PID_FILE"
        # Kill all processes in our process group
        kill -- -$$ 2>/dev/null
        exit 0
    }

    # Trap for cleanup
    trap cleanup_daemon SIGTERM SIGINT

    # Start interface listener in background (e.g., Telegram polling)
    interface_start &
    local interface_pid=$!

    # Heartbeat loop (optional)
    if [[ "${HEARTBEAT_ENABLED:-true}" == "true" ]] && [[ "${HEARTBEAT_INTERVAL:-0}" -gt 0 ]]; then
        heartbeat_loop() {
            local heartbeat_message
            heartbeat_message="Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."

            while true; do
                sleep "$HEARTBEAT_INTERVAL"

                # Use a dedicated session to avoid polluting user sessions
                init_session "heartbeat"
                local response
                response=$(capture_output process_message "heartbeat" "$heartbeat_message" "daemon")

                if [[ "$response" != "HEARTBEAT_OK" ]]; then
                    log_info "Heartbeat response: $response"
                else
                    log_debug "Heartbeat OK"
                fi
            done
        }

        heartbeat_loop &
        local heartbeat_pid=$!
    fi

    # Main loop: listen on named pipe for CLI/programmatic input
    log_info "Listening on pipe: $INPUT_PIPE"

    while true; do
        # Read from input pipe (blocks until data available)
        # Suppress errors from interrupted system calls (e.g., when stopping daemon)
        {
            if read -r line < "$INPUT_PIPE"; then
                # Parse input: SESSION_ID|SOURCE|MESSAGE
                local session_id source message
                session_id=$(echo "$line" | cut -d'|' -f1)
                source=$(echo "$line" | cut -d'|' -f2)
                message=$(echo "$line" | cut -d'|' -f3-)

                handle_incoming_message "$session_id" "$source" "$message"
            fi
        } 2>/dev/null
    done
}

# ============================================================================
# Pipe Communication
# ============================================================================

send_message() {
    local message="$1"
    local session_id="${2:-pipe_client}"
    local source="${3:-pipe}"

    # Check if daemon is running
    if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Error: Bashobot daemon is not running." >&2
        echo "Start it with: ./bashobot.sh -daemon" >&2
        exit 1
    fi

    # Send message via pipe
    echo "${session_id}|${source}|${message}" > "$INPUT_PIPE"

    # Wait for response
    local response
    while read -r line < "$OUTPUT_PIPE"; do
        local resp_session resp_message
        resp_session=$(echo "$line" | cut -d'|' -f1)
        resp_message=$(echo "$line" | cut -d'|' -f2-)

        if [[ "$resp_session" == "$session_id" ]]; then
            # Decode base64 response
            echo "$resp_message" | base64 -d
            break
        fi
    done
}

# Enqueue a message to daemon without waiting for a response
enqueue_message() {
    local message="$1"
    local session_id="${2:-pipe_client}"
    local source="${3:-pipe}"

    echo "${session_id}|${source}|${message}" > "$INPUT_PIPE"
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    cat << 'EOF'
Bashobot - A personal AI assistant in pure bash

USAGE:
    ./bashobot.sh [OPTIONS]

OPTIONS:
    -daemon             Start the main agent loop (background service)
    -t "message"        Send a single message to the running daemon
    -cli                Interactive CLI mode (connects to daemon via pipes)
    -status             Check if daemon is running
    -stop               Stop the running daemon
    -help               Show this help message

ENVIRONMENT VARIABLES:
    BASHOBOT_LLM        LLM provider (gemini, claude, openai)
    BASHOBOT_INTERFACE  Interface (telegram, none)
    BASHOBOT_CONFIG_DIR Config directory (default: ~/.bashobot)
    VERBOSE=1           Enable verbose output

CONFIGURATION:
    Edit ~/.bashobot/config.env with your API keys

EXAMPLES:
    # Start daemon with Telegram
    ./bashobot.sh -daemon

    # Start daemon without external interfaces (CLI only)
    BASHOBOT_INTERFACE=none ./bashobot.sh -daemon

    # Interactive CLI
    ./bashobot.sh -cli

    # Send a single message
    ./bashobot.sh -t "Hello"
EOF
}
