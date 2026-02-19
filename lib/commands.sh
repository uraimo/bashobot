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

    local provider_arg=""
    case "${1:-}" in
        gemini|claude|openai|gemini-sub|openai-sub|antigravity-sub)
            provider_arg="$1"
            shift
            ;;
    esac

    local model_name="$*"

    if [ -z "$model_name" ]; then
        # Show current model
        echo "Current provider: $LLM_PROVIDER"
        case "$LLM_PROVIDER" in
            gemini)          echo "Current model: ${GEMINI_MODEL:-gemini-3-flash-preview}" ;;
            gemini-sub)      echo "Current model: ${GEMINI_SUB_MODEL:-gemini-3-flash-preview}" ;;
            claude)          echo "Current model: ${CLAUDE_MODEL:-claude-haiku-4-5}" ;;
            openai)          echo "Current model: ${OPENAI_MODEL:-gpt-5-nano}" ;;
            openai-sub)      echo "Current model: ${OPENAI_SUB_MODEL:-gpt-5-nano}" ;;
            antigravity-sub) echo "Current model: ${ANTIGRAVITY_SUB_MODEL:-gemini-3-flash}" ;;
            *)               echo "Current model: unknown" ;;
        esac
        echo ""
        echo "Usage: /model [provider] <modelname>"
        echo "Examples:"
        echo "  /model gemini-3-pro-preview"
        echo "  /model claude-haiku-4-5"
        echo "  /model gpt-5-nano"
        echo "  /model openai-sub gpt-5.1-codex"
        echo "  /model antigravity-sub gemini-3-flash"
        return 0
    fi

    local provider=""
    if [[ -n "$provider_arg" ]]; then
        provider="$provider_arg"
    else
        case "$LLM_PROVIDER" in
            gemini-sub)
                [[ "$model_name" == gemini-* ]] && provider="gemini-sub"
                ;;
            openai-sub)
                [[ "$model_name" == gpt-* || "$model_name" == o1-* || "$model_name" == o3-* ]] && provider="openai-sub"
                ;;
            antigravity-sub)
                provider="antigravity-sub"
                ;;
        esac
    fi

    if [[ -z "$provider" ]]; then
        case "$model_name" in
            gemini-*)
                provider="gemini"
                ;;
            claude-*|anthropic-*)
                provider="claude"
                ;;
            gpt-*|o1-*|o3-*)
                provider="openai"
                ;;
            *)
                echo "Unknown model: $model_name"
                echo "Model name should start with: gemini-, claude-, gpt-, o1-, o3-"
                echo "Or specify a provider: /model <provider> <modelname>"
                return 0
                ;;
        esac
    fi

    case "$provider" in
        gemini)
            export GEMINI_MODEL="$model_name"
            export LLM_PROVIDER="gemini"
            source "$BASHOBOT_DIR/providers/gemini.sh" 2>/dev/null
            echo "Switched to Gemini model: $model_name"
            echo "Current model: ${GEMINI_MODEL}"
            config_write_runtime "gemini" "$GEMINI_MODEL"
            ;;
        gemini-sub)
            export GEMINI_SUB_MODEL="$model_name"
            export LLM_PROVIDER="gemini-sub"
            source "$BASHOBOT_DIR/providers/gemini-sub.sh" 2>/dev/null
            echo "Switched to Gemini subscription model: $model_name"
            echo "Current model: ${GEMINI_SUB_MODEL}"
            config_write_runtime "gemini-sub" "$GEMINI_SUB_MODEL"
            ;;
        claude)
            export CLAUDE_MODEL="$model_name"
            export LLM_PROVIDER="claude"
            source "$BASHOBOT_DIR/providers/claude.sh" 2>/dev/null
            echo "Switched to Claude model: $model_name"
            echo "Current model: ${CLAUDE_MODEL}"
            config_write_runtime "claude" "$CLAUDE_MODEL"
            ;;
        openai)
            export OPENAI_MODEL="$model_name"
            export LLM_PROVIDER="openai"
            source "$BASHOBOT_DIR/providers/openai.sh" 2>/dev/null
            echo "Switched to OpenAI model: $model_name"
            echo "Current model: ${OPENAI_MODEL}"
            config_write_runtime "openai" "$OPENAI_MODEL"
            ;;
        openai-sub)
            export OPENAI_SUB_MODEL="$model_name"
            export LLM_PROVIDER="openai-sub"
            source "$BASHOBOT_DIR/providers/openai-sub.sh" 2>/dev/null
            echo "Switched to OpenAI subscription model: $model_name"
            echo "Current model: ${OPENAI_SUB_MODEL}"
            config_write_runtime "openai-sub" "$OPENAI_SUB_MODEL"
            ;;
        antigravity-sub)
            export ANTIGRAVITY_SUB_MODEL="$model_name"
            export LLM_PROVIDER="antigravity-sub"
            source "$BASHOBOT_DIR/providers/antigravity-sub.sh" 2>/dev/null
            echo "Switched to Antigravity subscription model: $model_name"
            echo "Current model: ${ANTIGRAVITY_SUB_MODEL}"
            config_write_runtime "antigravity-sub" "$ANTIGRAVITY_SUB_MODEL"
            ;;
        *)
            echo "Unknown provider: $provider"
            return 0
            ;;
    esac

    return 0
}

# ============================================================================
# Command: /models [provider]
# List available models from providers
# ============================================================================
_models_http_get() {
    local url="$1"
    shift
    local tmp
    tmp=$(mktemp)
    MODELS_HTTP_CODE=$(curl -s -o "$tmp" -w "%{http_code}" "$url" "$@")
    MODELS_HTTP_BODY=$(cat "$tmp")
    rm -f "$tmp"
}

cmd_models() {
    local session_id="$1"

    if declare -F models_list >/dev/null 2>&1; then
        models_list
    else
        echo "Model listing not available for current provider."
    fi
    return 0
}

# ============================================================================
# Command: /login [provider]
# Start OAuth login (use CLI option)
# ============================================================================
cmd_login() {
    local session_id="$1"
    shift
    local provider="$1"

    if [[ -z "$provider" ]]; then
        echo "Usage: /login <provider>"
        echo "Available providers: openai-sub, gemini-sub, antigravity-sub"
        echo ""
        echo "Run the OAuth flow from your terminal:"
        echo "  ./bashobot.sh -login <provider>"
        return 0
    fi

    echo "OAuth login is interactive. Run this in a terminal:"
    echo "  ./bashobot.sh -login $provider"
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
    echo "  /models        - List available models for current provider"
    echo "  /tools [on|off]- Show or toggle tool usage"
    echo "  /login [p]    - OAuth login (run ./bashobot.sh -login <provider>)"
    echo "  /allowcmd [c]  - Allow a shell command for tool execution"
    echo "  /memory [cmd]  - Memory system (list|save|search|clear)"
    echo "  /context       - Show session context/token usage"
    echo "  /new          - Start a new conversation"
    echo "  /compact       - Force compact the conversation"
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
            echo "  - memory_search: Search past conversations"
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
# Command: /allowcmd [command]
# Allow a shell command for tool execution
# ============================================================================
cmd_allowcmd() {
    local session_id="$1"
    shift
    local command="$*"

    if [[ -z "$command" ]]; then
        # List current whitelist
        ensure_command_whitelist_file
        if [[ -s "$BASHOBOT_CMD_WHITELIST_FILE" ]]; then
            echo "Allowed commands:"
            cat "$BASHOBOT_CMD_WHITELIST_FILE"
        else
            echo "No commands have been approved yet."
        fi
        echo ""
        echo "Usage: /allowcmd <command>"
        return 0
    fi

    local cmd_name
    cmd_name=$(extract_command_name "$command")

    if [[ -z "$cmd_name" ]]; then
        echo "Error: unable to determine command name."
        return 0
    fi

    add_command_to_whitelist "$cmd_name"
    echo "Allowed command: $cmd_name"
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
            cmd_memory_list "$args"
            ;;
        save)
            cmd_memory_save "$session_id"
            ;;
        search|find)
            cmd_memory_search "$args"
            ;;
        clear)
            cmd_memory_clear
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
    
    echo "Session: $session_id"
    get_session_stats "$session_id"
    return 0
}

# ============================================================================
# Command: /new
# Start a new conversation (optionally saves to memory first)
# ============================================================================
cmd_new() {
    local session_id="$1"

    # Save to memory before clearing if memory is enabled
    if [[ "$BASHOBOT_MEMORY_ENABLED" == "true" ]]; then
        local saved
        saved=$(save_session_to_memory "$session_id" 2>/dev/null)
        if [[ -n "$saved" ]]; then
            echo "Saved conversation to memory: $saved"
        fi
    fi

    clear_session "$session_id"
    echo "Conversation cleared. Starting fresh!"
    return 0
}

# ============================================================================
# Command: /compact
# Force compact the current conversation
# ============================================================================
cmd_compact() {
    local session_id="$1"

    force_summarize "$session_id"
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
        models)
            cmd_models "$session_id"
            return $?
            ;;
        tools)
            cmd_tools "$session_id" $args
            return $?
            ;;
        login)
            cmd_login "$session_id" $args
            return $?
            ;;
        allowcmd)
            cmd_allowcmd "$session_id" $args
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
        new)
            cmd_new "$session_id" $args
            return $?
            ;;
        compact)
            cmd_compact "$session_id" $args
            return $?
            ;;
        *)
            echo "Unknown command: /$cmd"
            echo "Type /help for available commands."
            return 0
            ;;
    esac
}
