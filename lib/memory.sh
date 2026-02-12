#!/bin/bash
#
# Bashobot Memory System (Markdown-based)
#
# Uses markdown files under ~/.bashobot/memory and optional MEMORY.md
#

# ============================================================================
# Configuration
# ============================================================================

# Enable/disable memory system (default: enabled)
BASHOBOT_MEMORY_ENABLED="${BASHOBOT_MEMORY_ENABLED:-true}"

# Memory storage directory (markdown notes)
MEMORY_DIR="${CONFIG_DIR}/workspace/memory"
MEMORY_MAIN_FILE="${CONFIG_DIR}/workspace/MEMORY.md"

# Maximum matches to return
MAX_MEMORIES_IN_CONTEXT="${MAX_MEMORIES_IN_CONTEXT:-3}"

# Minimum messages before saving to memory
MIN_MESSAGES_FOR_MEMORY="${MIN_MESSAGES_FOR_MEMORY:-4}"

# ============================================================================
# Initialization
# ============================================================================

init_memory() {
    mkdir -p "$MEMORY_DIR"
}

memory_today() {
    date "+%Y-%m-%d"
}

memory_yesterday() {
    if date -v-1d "+%Y-%m-%d" >/dev/null 2>&1; then
        date -v-1d "+%Y-%m-%d"
    else
        date -d "yesterday" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d"
    fi
}

memory_daily_file() {
    local day="$1"
    echo "$MEMORY_DIR/${day}.md"
}

# ============================================================================
# Memory Storage
# ============================================================================

save_to_memory() {
    local session_id="$1"
    local summary="$2"

    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        return 0
    fi

    if [[ -z "$summary" ]]; then
        log_error "Cannot save empty summary to memory"
        return 1
    fi

    init_memory

    local day
    day=$(memory_today)
    local file
    file=$(memory_daily_file "$day")

    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    {
        echo "## ${timestamp} (session: ${session_id})"
        echo "$summary"
        echo ""
    } >> "$file"

    log_info "Saved memory note: $file"
    echo "$file"
}

save_session_to_memory() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    local message_count
    message_count=$(jq '.messages | length' "$session_file")

    if [[ $message_count -lt $MIN_MESSAGES_FOR_MEMORY ]]; then
        log_info "Not enough messages to save to memory ($message_count < $MIN_MESSAGES_FOR_MEMORY)"
        return 0
    fi

    local messages
    messages=$(jq -c '.messages' "$session_file")
    local summary
    summary=$(generate_summary "$messages")

    if [[ -z "$summary" ]] || [[ "$summary" == "Error:"* ]]; then
        log_error "Failed to generate summary for memory: $summary"
        return 1
    fi

    save_to_memory "$session_id" "$summary"
}

# ============================================================================
# Memory Retrieval
# ============================================================================

search_memories() {
    local query="$1"
    local max_results="${2:-$MAX_MEMORIES_IN_CONTEXT}"

    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo "[]"
        return
    fi

    if [[ -z "$query" ]]; then
        echo "[]"
        return
    fi

    init_memory

    local results="[]"
    local count=0

    local files=()
    if [[ -f "$MEMORY_MAIN_FILE" ]]; then
        files+=("$MEMORY_MAIN_FILE")
    fi
    for file in "$MEMORY_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        files+=("$file")
    done

    local file
    for file in "${files[@]:-}"; do
        while IFS= read -r match; do
            local line
            line="${match%%:*}"
            local text
            text="${match#*:}"
            results=$(echo "$results" | jq --arg file "$file" --argjson line "$line" --arg text "$text" '. + [{file: $file, line: $line, text: $text}]')
            count=$((count + 1))
            if [[ $count -ge $max_results ]]; then
                break 2
            fi
        done < <(grep -n -i -- "$query" "$file" 2>/dev/null)
    done

    echo "$results"
}

# Load relevant memories into a message for context
get_memory_context() {
    local user_message="$1"

    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo ""
        return
    fi

    local relevant
    relevant=$(search_memories "$user_message" "$MAX_MEMORIES_IN_CONTEXT")

    local count
    count=$(echo "$relevant" | jq 'length')
    if [[ $count -eq 0 ]]; then
        echo ""
        return
    fi

    local context="Relevant memory notes:\n\n"
    local i
    for ((i=0; i<count; i++)); do
        local file line text
        file=$(echo "$relevant" | jq -r ".[$i].file")
        line=$(echo "$relevant" | jq -r ".[$i].line")
        text=$(echo "$relevant" | jq -r ".[$i].text")
        context+="[$(basename "$file"):$line] $text\n"
    done

    echo -e "$context"
}

inject_memory_context() {
    local messages="$1"
    local user_message="$2"

    local memory_context
    memory_context=$(get_memory_context "$user_message")

    if [[ -z "$memory_context" ]]; then
        echo "$messages"
        return
    fi

    echo "$messages" | jq --arg context "$memory_context" \
        '[{
            "role": "user",
            "content": $context
        }, {
            "role": "assistant",
            "content": "I have relevant memory notes that may help."
        }] + .'
}

# ============================================================================
# Memory Commands (for commands.sh)
# ============================================================================

cmd_memory_list() {
    local limit="${1:-5}"

    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo "Memory system is disabled."
        echo "Enable with: BASHOBOT_MEMORY_ENABLED=true"
        return 0
    fi

    init_memory

    echo "Memory Files"
    echo "============="

    if [[ -f "$MEMORY_MAIN_FILE" ]]; then
        echo "- MEMORY.md"
    fi

    local files
    files=$(ls -1t "$MEMORY_DIR"/*.md 2>/dev/null | head -n "$limit")
    if [[ -n "$files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            echo "- $(basename "$file")"
        done <<< "$files"
    else
        echo "(no daily memory files found)"
    fi
}

cmd_memory_save() {
    local session_id="$1"

    echo "Saving session to memory..."

    local file
    file=$(save_session_to_memory "$session_id")

    if [[ -n "$file" ]]; then
        echo "Saved to: $file"
    else
        echo "Nothing to save (not enough messages or save failed)"
    fi
}

cmd_memory_search() {
    local query="$1"

    if [[ -z "$query" ]]; then
        echo "Usage: /memory search <query>"
        return 0
    fi

    echo "Searching memory files for: $query"
    echo ""

    local results
    results=$(search_memories "$query" 10)

    local count
    count=$(echo "$results" | jq 'length')

    if [[ $count -eq 0 ]]; then
        echo "No relevant memory notes found."
    else
        echo "$results" | jq -r '.[] | "[" + (.file | split("/") | last) + ":" + (.line|tostring) + "] " + .text'
    fi
}

cmd_memory_clear() {
    init_memory

    rm -f "$MEMORY_DIR"/*.md
    rm -f "$MEMORY_MAIN_FILE"

    echo "Cleared memory files."
}
