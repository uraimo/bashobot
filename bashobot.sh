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
# Load Libraries
# ============================================================================

source "$BASHOBOT_DIR/lib/tools.sh"
source "$BASHOBOT_DIR/lib/session.sh"
source "$BASHOBOT_DIR/lib/memory.sh"
source "$BASHOBOT_DIR/lib/oauth.sh"
source "$BASHOBOT_DIR/lib/commands.sh"
source "$BASHOBOT_DIR/lib/approval.sh"
source "$BASHOBOT_DIR/lib/config.sh"
source "$BASHOBOT_DIR/lib/json.sh"
source "$BASHOBOT_DIR/lib/core.sh"

# ============================================================================
# Status / Stop
# ============================================================================

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

    case "${1:-}" in
        -daemon)
            load_provider "$LLM_PROVIDER"
            load_interface "$INTERFACE"
            daemon_loop
            ;;
        -t)
            [[ -z "${2:-}" ]] && { echo "Error: Message required"; exit 1; }
            load_provider "$LLM_PROVIDER"
            send_message "$2"
            ;;
        -cli)
            load_provider "$LLM_PROVIDER"
            # Interactive mode that talks to daemon via pipes
            echo ""
            echo ""
            source "$BASHOBOT_DIR/lib/logo.sh"
            echo ""
            echo ""
            echo -e "\033[1;33mWelcome to Bashobot CLI!\033[0m"
            echo ""
            echo -e "Type \033[38;5;202m/help\033[0m for commands, \033[38;5;202m/exit\033[0m to quit"
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
        -login)
            [[ -z "${2:-}" ]] && { echo "Error: Provider required"; exit 1; }
            oauth_login_provider "$2"
            ;;
        -logout)
            [[ -z "${2:-}" ]] && { echo "Error: Provider required"; exit 1; }
            oauth_logout_provider "$2"
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
