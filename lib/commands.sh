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
    echo "  /tools [on|off]- Show or toggle tool usage"
    echo "  /memory [cmd]  - Memory system (list|save|search|clear)"
    echo "  /context       - Show session context/token usage"
    echo "  /clear         - Clear conversation history"
    echo "  /summarize     - Force summarize the conversation"
    echo "  /help          - Show this help message"
    echo "  /exit          - Exit the CLI session (CLI only)"
    echo ""
    echo "Any other input is sent to the AI assistant."
    return 0
}

# ============================================================================
# Command: /tools [on|off]
# Show or toggle tool usage
# ============================================================================
cmd_tools() {
    local session_id="$1"
    shift
    local action="$*"
    
    if [[ -z "$action" ]]; then
        echo "Tools enabled: $BASHOBOT_TOOLS_ENABLED"
        echo ""
        if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]]; then
            echo "Available tools:"
            echo "  - bash: Execute shell commands"
            echo "  - read_file: Read file contents"
            echo "  - write_file: Write to files"
            echo "  - list_files: List directory contents"
        fi
        echo ""
        echo "Usage: /tools on|off"
        return 0
    fi
    
    case "$action" in
        on|true|enable|enabled)
            export BASHOBOT_TOOLS_ENABLED="true"
            echo "Tools enabled."
            ;;
        off|false|disable|disabled)
            export BASHOBOT_TOOLS_ENABLED="false"
            echo "Tools disabled."
            ;;
        *)
            echo "Unknown option: $action"
            echo "Usage: /tools on|off"
            ;;
    esac
    return 0
}

# ============================================================================
# Command: /memory [subcommand]
# Memory system management
# ============================================================================
cmd_memory() {
    local session_id="$1"
    shift
    local subcommand="$1"
    shift 2>/dev/null || true
    local args="$*"
    
    if [[ -z "$subcommand" ]]; then
        subcommand="list"
    fi
    
    case "$subcommand" in
        list|ls)
            if type cmd_memory_list &>/dev/null; then
                cmd_memory_list "$args"
            else
                echo "Memory system not available."
            fi
            ;;
        save)
            if type cmd_memory_save &>/dev/null; then
                cmd_memory_save "$session_id"
            else
                echo "Memory system not available."
            fi
            ;;
        search|find)
            if type cmd_memory_search &>/dev/null; then
                cmd_memory_search "$args"
            else
                echo "Memory system not available."
            fi
            ;;
        clear)
            if type cmd_memory_clear &>/dev/null; then
                cmd_memory_clear
            else
                echo "Memory system not available."
            fi
            ;;
        on|enable)
            export BASHOBOT_MEMORY_ENABLED="true"
            echo "Memory system enabled."
            ;;
        off|disable)
            export BASHOBOT_MEMORY_ENABLED="false"
            echo "Memory system disabled."
            ;;
        *)
            echo "Unknown memory subcommand: $subcommand"
            echo ""
            echo "Usage: /memory [command]"
            echo "  list         - Show recent memories (default)"
            echo "  save         - Save current session to memory"
            echo "  search <q>   - Search memories by keyword"
            echo "  clear        - Delete all memories"
            echo "  on|off       - Enable/disable memory system"
            ;;
    esac
    return 0
}

# ============================================================================
# Command: /context
# Show current session context usage
# ============================================================================
cmd_context() {
    local session_id="$1"
    
    if type get_session_stats &>/dev/null; then
        echo "Session: $session_id"
        get_session_stats "$session_id"
    else
        echo "Session management not available."
    fi
    return 0
}

# ============================================================================
# Command: /clear
# Clear conversation history (optionally saves to memory first)
# ============================================================================
cmd_clear() {
    local session_id="$1"
    
    # Save to memory before clearing if memory is enabled
    if [[ "$BASHOBOT_MEMORY_ENABLED" == "true" ]] && type save_session_to_memory &>/dev/null; then
        local saved
        saved=$(save_session_to_memory "$session_id" 2>/dev/null)
        if [[ -n "$saved" ]]; then
            echo "Saved conversation to memory: $saved"
        fi
    fi
    
    if type clear_session &>/dev/null; then
        clear_session "$session_id"
        echo "Conversation cleared. Starting fresh!"
    else
        # Fallback if session lib not loaded
        local session_file
        session_file=$(get_session_file "$session_id")
        echo '{"messages":[]}' | jq '.' > "$session_file"
        echo "Conversation cleared. Starting fresh!"
    fi
    return 0
}

# ============================================================================
# Command: /summarize
# Force summarize the current conversation
# ============================================================================
cmd_summarize() {
    local session_id="$1"
    
    if type force_summarize &>/dev/null; then
        force_summarize "$session_id"
    else
        echo "Session summarization not available."
    fi
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
        tools)
            cmd_tools "$session_id" $args
            return $?
            ;;
        memory)
            cmd_memory "$session_id" $args
            return $?
            ;;
        help)
            cmd_help "$session_id" $args
            return $?
            ;;
        context)
            cmd_context "$session_id" $args
            return $?
            ;;
        clear)
            cmd_clear "$session_id" $args
            return $?
            ;;
        summarize)
            cmd_summarize "$session_id" $args
            return $?
            ;;
        *)
            echo "Unknown command: /$cmd"
            echo "Type /help for available commands."
            return 0
            ;;
    esac
}
