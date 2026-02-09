#!/bin/bash
#
# Bashobot - A personal AI assistant in pure bash
# Usage:
#   ./bashobot.sh -daemon         Start the main agent loop
#   ./bashobot.sh -t "message"    Send a message to the agent
#   ./bashobot.sh -cli            Interactive CLI mode
#   ./bashobot.sh -help           Show help
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

BASHOBOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BASHOBOT_CONFIG_DIR:-$HOME/.bashobot}"
SESSIONS_DIR="$CONFIG_DIR/sessions"
PIPE_DIR="$CONFIG_DIR/pipes"
LOG_FILE="$CONFIG_DIR/bashobot.log"
PID_FILE="$CONFIG_DIR/bashobot.pid"

# Named pipes for IPC
INPUT_PIPE="$PIPE_DIR/input.pipe"
OUTPUT_PIPE="$PIPE_DIR/output.pipe"

# ============================================================================
# Initialization
# ============================================================================

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$SESSIONS_DIR" "$PIPE_DIR"
    
    # Create config file if not exists
    if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
        cat > "$CONFIG_DIR/config.env" << 'EOF'
# Bashobot Configuration
# Uncomment and set your API keys

# LLM Provider (gemini, claude, openai)
#BASHOBOT_LLM=gemini

# Gemini
#GEMINI_API_KEY=your_key_here

# Claude
#ANTHROPIC_API_KEY=your_key_here

# OpenAI
#OPENAI_API_KEY=your_key_here

# Telegram
#TELEGRAM_BOT_TOKEN=your_token_here
#TELEGRAM_ALLOWED_USERS=user_id1,user_id2

# Interface (telegram, cli)
#BASHOBOT_INTERFACE=telegram

# Heartbeat
#BASHOBOT_HEARTBEAT_ENABLED=true
#BASHOBOT_HEARTBEAT_INTERVAL=300

# Command whitelist
#BASHOBOT_CMD_WHITELIST_ENABLED=true
# Command whitelist file
#BASHOBOT_CMD_WHITELIST_FILE=~/.bashobot/command_whitelist
EOF
        echo "Created config file: $CONFIG_DIR/config.env"
        echo "Please edit it with your API keys."
        exit 1
    fi
    
    # Load config
    source "$CONFIG_DIR/config.env"
    
    # Set defaults AFTER loading config (so env vars take precedence)
    LLM_PROVIDER="${BASHOBOT_LLM:-gemini}"
    INTERFACE="${BASHOBOT_INTERFACE:-telegram}"
    HEARTBEAT_ENABLED="${BASHOBOT_HEARTBEAT_ENABLED:-true}"
    HEARTBEAT_INTERVAL="${BASHOBOT_HEARTBEAT_INTERVAL:-300}"

    # Load runtime overrides if present (e.g., last /model)
    if [[ -f "$CONFIG_DIR/runtime.env" ]]; then
        source "$CONFIG_DIR/runtime.env"
    fi
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
# Load Libraries
# ============================================================================

if [[ -f "$BASHOBOT_DIR/lib/tools.sh" ]]; then
    source "$BASHOBOT_DIR/lib/tools.sh"
fi

if [[ -f "$BASHOBOT_DIR/lib/session.sh" ]]; then
    source "$BASHOBOT_DIR/lib/session.sh"
fi

if [[ -f "$BASHOBOT_DIR/lib/memory.sh" ]]; then
    source "$BASHOBOT_DIR/lib/memory.sh"
fi

if [[ -f "$BASHOBOT_DIR/lib/commands.sh" ]]; then
    source "$BASHOBOT_DIR/lib/commands.sh"
fi

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

init_session() {
    local session_id="${1:-default}"
    local session_file
    session_file=$(get_session_file "$session_id")
    
    if [[ ! -f "$session_file" ]]; then
        echo '{"messages":[]}' | jq '.' > "$session_file"
    fi
}

append_message() {
    local session_id="$1"
    local role="$2"
    local content="$3"
    local session_file
    session_file=$(get_session_file "$session_id")
    
    # Use --arg to properly escape content as a JSON string
    jq --arg role "$role" --arg content "$content" \
        '.messages += [{"role": $role, "content": $content}]' \
        "$session_file" > "${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
}

get_messages() {
    local session_id="$1"
    local session_file
    session_file=$(get_session_file "$session_id")
    
    jq -c '.messages' "$session_file"
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
    
    log_info "Processing message from $source: ${user_message:0:50}..."

    # Check if it's a command
    if [[ "$user_message" == /* ]] && type process_command &>/dev/null; then
        local cmd_output cmd_output_file
        cmd_output_file=$(mktemp)
        process_command "$session_id" "$user_message" > "$cmd_output_file"
        local cmd_status=$?
        cmd_output=$(cat "$cmd_output_file")
        rm -f "$cmd_output_file"

        if [[ $cmd_status -eq 0 ]]; then
            # Command handled, return output
            echo "$cmd_output"
            return 0
        fi
        # cmd_status == 1 means not a command, continue to LLM
    fi

    # Handle pending command approvals (non-slash input only)
    if type get_pending_approval &>/dev/null; then
        local pending_cmd
        pending_cmd=$(get_pending_approval "$session_id")
        if [[ -n "$pending_cmd" ]]; then
            local decision
            decision=$(echo "$user_message" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$decision" == "yes" ]]; then
                if type add_command_to_whitelist &>/dev/null; then
                    add_command_to_whitelist "$pending_cmd"
                fi
                clear_pending_approval "$session_id"
                echo "Approved command: $pending_cmd"
                return 0
            fi
            clear_pending_approval "$session_id"
            echo "Error: command denied: $pending_cmd"
            return 0
        fi
    fi
    
    # Add user message to session
    append_message "$session_id" "user" "$user_message"
    
    # Check if we need to summarize before calling LLM
    if type check_and_summarize &>/dev/null; then
        check_and_summarize "$session_id"
    fi
    
    # Get conversation history (includes summary if present)
    local messages
    if type get_messages_for_llm &>/dev/null; then
        messages=$(get_messages_for_llm "$session_id")
    else
        messages=$(get_messages "$session_id")
    fi
    
    # Inject relevant memory context if this is the first message in session
    local msg_count
    msg_count=$(echo "$messages" | jq 'length')
    if [[ $msg_count -le 2 ]] && type inject_memory_context &>/dev/null; then
        messages=$(inject_memory_context "$messages" "$user_message")
    fi
    
    # Call LLM provider (function defined in provider script)
    local response
    set +e
    response=$(llm_chat "$messages")
    local llm_status=$?
    set -e
    
    if [[ $llm_status -ne 0 ]] || [[ -z "$response" ]]; then
        response="Sorry, I encountered an error processing your message."
        log_error "LLM error (status=$llm_status) or empty response"
    fi
    
    # Add assistant response to session
    append_message "$session_id" "assistant" "$response"
    
    echo "$response"
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
                local response response_file
                response_file=$(mktemp)
                process_message "heartbeat" "$heartbeat_message" "daemon" > "$response_file"
                response=$(cat "$response_file")
                rm -f "$response_file"

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
                
                [[ -z "$message" ]] && continue
                
                init_session "$session_id"
                
                local response response_file
                response_file=$(mktemp)
                process_message "$session_id" "$message" "$source" > "$response_file"
                response=$(cat "$response_file")
                rm -f "$response_file"
                
                # Write response to output pipe (base64 encode to handle newlines)
                local encoded_response
                encoded_response=$(echo "$response" | base64)
                echo "${session_id}|${encoded_response}" > "$OUTPUT_PIPE"
                
                # Also send via interface if applicable
                if [[ "$source" == "telegram" ]]; then
                    interface_send "$session_id" "$response"
                fi
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
    
    # Check if daemon is running
    if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Error: Bashobot daemon is not running." >&2
        echo "Start it with: ./bashobot.sh -daemon" >&2
        exit 1
    fi
    
    # Send message via pipe
    echo "${session_id}|pipe|${message}" > "$INPUT_PIPE"
    
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

    # Interactive CLI (requires daemon running)
    ./bashobot.sh -cli

    # Send a message to running daemon
    ./bashobot.sh -t "What's the weather like?"

    # Use Claude instead of Gemini
    BASHOBOT_LLM=claude ./bashobot.sh -daemon
EOF
}

status_check() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Bashobot daemon is running (PID: $(cat "$PID_FILE"))"
        return 0
    else
        echo "Bashobot daemon is not running"
        return 1
    fi
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Find all descendant PIDs and kill them
            local all_pids
            all_pids=$(pstree -p "$pid" 2>/dev/null | grep -oE '[0-9]+' | sort -u || echo "$pid")
            
            # If pstree not available, use pgrep recursively
            if [[ -z "$all_pids" ]]; then
                all_pids="$pid $(pgrep -P "$pid" 2>/dev/null) $(pgrep -P "$(pgrep -P "$pid" 2>/dev/null)" 2>/dev/null)"
            fi
            
            # Kill all found PIDs
            for p in $all_pids; do
                kill "$p" 2>/dev/null || true
            done
            
            sleep 0.5
            
            # Force kill any remaining
            for p in $all_pids; do
                kill -9 "$p" 2>/dev/null || true
            done
            
            echo "Stopped Bashobot daemon (PID: $pid)"
        else
            echo "Daemon not running, cleaning up PID file"
        fi
        rm -f "$PID_FILE"
    else
        echo "No PID file found"
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    init_dirs
    load_provider "$LLM_PROVIDER"
    
    case "${1:-}" in
        -daemon)
            load_interface "$INTERFACE"
            daemon_loop
            ;;
        -t)
            [[ -z "${2:-}" ]] && { echo "Error: Message required"; exit 1; }
            send_message "$2"
            ;;
        -cli)
            # Interactive mode that talks to daemon via pipes
            echo "╔════════════════════════════════════════════╗"
            echo "║       Bashobot Interactive CLI             ║"
            echo "║  Type /help for commands, /exit to quit    ║"
            echo "╚════════════════════════════════════════════╝"
            echo ""
            local session_id="cli_$$"
            while true; do
                echo -n "You: "
                read -r input || break  # Handle Ctrl+D
                [[ -z "$input" ]] && continue
                [[ "$input" == "/exit" ]] && { echo "Goodbye!"; break; }
                echo -n "Bot: "
                send_message "$input" "$session_id"
                echo ""
            done
            ;;
        -status)
            status_check
            ;;
        -stop)
            stop_daemon
            ;;
        -help|--help|"")
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
