#!/bin/bash
#
# Bashobot Commands
#
# Commands start with / and are processed before being sent to the LLM
# Returns: 0 = command handled, 1 = not a command (send to LLM)
# Output to stdout is sent as the response
#

# ============================================================================
# Command: /model [modelname]
# Switch to a different model or show current model
# ============================================================================
cmd_model() {
    local session_id="$1"
    shift
    local model_name="$*"
    
    if [ -z "$model_name" ]; then
        # Show current model
        echo "Current provider: $LLM_PROVIDER"
        case "$LLM_PROVIDER" in
            gemini)  echo "Current model: ${GEMINI_MODEL:-gemini-2.5-flash}" ;;
            claude)  echo "Current model: ${CLAUDE_MODEL:-claude-sonnet-4-20250514}" ;;
            openai)  echo "Current model: ${OPENAI_MODEL:-gpt-4o}" ;;
            *)       echo "Current model: unknown" ;;
        esac
        echo ""
        echo "Usage: /model <modelname>"
        echo "Examples:"
        echo "  /model gemini-2.5-pro"
        echo "  /model claude-sonnet-4-20250514"
        echo "  /model gpt-4o"
        return 0
    fi
    
    # Detect provider from model name and set accordingly
    case "$model_name" in
        gemini-*)
            export GEMINI_MODEL="$model_name"
            export LLM_PROVIDER="gemini"
            source "$BASHOBOT_DIR/providers/gemini.sh" 2>/dev/null
            echo "Switched to Gemini model: $model_name"
            ;;
        claude-*|anthropic-*)
            export CLAUDE_MODEL="$model_name"
            export LLM_PROVIDER="claude"
            source "$BASHOBOT_DIR/providers/claude.sh" 2>/dev/null
            echo "Switched to Claude model: $model_name"
            ;;
        gpt-*|o1-*|o3-*)
            export OPENAI_MODEL="$model_name"
            export LLM_PROVIDER="openai"
            source "$BASHOBOT_DIR/providers/openai.sh" 2>/dev/null
            echo "Switched to OpenAI model: $model_name"
            ;;
        *)
            echo "Unknown model: $model_name"
            echo "Model name should start with: gemini-, claude-, gpt-, o1-, o3-"
            return 0
            ;;
    esac
    
    return 0
}

# ============================================================================
# Command: /help
# Show available commands
# ============================================================================
cmd_help() {
    local session_id="$1"
    echo "Available commands:"
    echo "  /model [name]  - Show or switch the current model"
    echo "  /help          - Show this help message"
    echo "  /exit          - Exit the CLI session (CLI only)"
    echo ""
    echo "Any other input is sent to the AI assistant."
    return 0
}

# ============================================================================
# Main command processor
# Called with: session_id, full_message
# Returns: 0 if command was handled, 1 if message should go to LLM
# ============================================================================
process_command() {
    local session_id="$1"
    local message="$2"
    
    # Check if message starts with /
    case "$message" in
        /*) ;;
        *) return 1 ;;
    esac
    
    # Parse command and args
    local cmd args
    cmd=$(echo "$message" | cut -d' ' -f1 | sed 's|^/||')
    args=$(echo "$message" | cut -d' ' -f2-)
    [ "$args" = "/$cmd" ] && args=""
    
    # Dispatch to command handler
    case "$cmd" in
        model)
            cmd_model "$session_id" $args
            return $?
            ;;
        help)
            cmd_help "$session_id" $args
            return $?
            ;;
        *)
            echo "Unknown command: /$cmd"
            echo "Type /help for available commands."
            return 0
            ;;
    esac
}
