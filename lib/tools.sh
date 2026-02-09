#!/bin/bash
#
# Bashobot Tools
#
# Provides bash execution and file read/write capabilities
#

# ============================================================================
# Configuration
# ============================================================================

# Enable/disable tools (default: enabled)
BASHOBOT_TOOLS_ENABLED="${BASHOBOT_TOOLS_ENABLED:-true}"

# Allowed directories for file operations (comma-separated, empty = allow all)
# For security, you may want to restrict this
BASHOBOT_ALLOWED_DIRS="${BASHOBOT_ALLOWED_DIRS:-}"

# Maximum output size for bash commands (in bytes)
BASHOBOT_MAX_OUTPUT="${BASHOBOT_MAX_OUTPUT:-50000}"

# Bash command timeout (in seconds)
BASHOBOT_BASH_TIMEOUT="${BASHOBOT_BASH_TIMEOUT:-30}"

# Enable/disable command whitelist (default: enabled)
BASHOBOT_CMD_WHITELIST_ENABLED="${BASHOBOT_CMD_WHITELIST_ENABLED:-true}"

# Command whitelist file (one command per line)
BASHOBOT_CMD_WHITELIST_FILE="${BASHOBOT_CMD_WHITELIST_FILE:-$CONFIG_DIR/command_whitelist}"

# Pending approval storage
BASHOBOT_CMD_APPROVAL_DIR="${BASHOBOT_CMD_APPROVAL_DIR:-$CONFIG_DIR/cmd_approvals}"

# ============================================================================
# Tool Definitions (for LLM API)
# ============================================================================

# Get tool definitions in a provider-agnostic format
# Each provider will convert this to their specific format
get_tools_definition() {
    if [[ "$BASHOBOT_TOOLS_ENABLED" != "true" ]]; then
        echo "[]"
        return
    fi
    
    cat << 'EOF'
[
  {
    "name": "bash",
    "description": "Execute a bash command and return the output. Use this to run shell commands, scripts, or system utilities. The command runs in a bash shell with a timeout. Be careful with destructive commands.",
    "parameters": {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The bash command to execute"
        },
        "working_dir": {
          "type": "string",
          "description": "Optional working directory for the command (defaults to home directory)"
        }
      },
      "required": ["command"]
    }
  },
  {
    "name": "read_file",
    "description": "Read the contents of a file. Returns the file contents as text. For binary files, returns a message indicating it's binary.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file to read (absolute or relative to home)"
        },
        "offset": {
          "type": "integer",
          "description": "Line number to start reading from (1-indexed, optional)"
        },
        "limit": {
          "type": "integer",
          "description": "Maximum number of lines to read (optional, default: 500)"
        }
      },
      "required": ["path"]
    }
  },
  {
    "name": "write_file",
    "description": "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Creates parent directories automatically.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file to write (absolute or relative to home)"
        },
        "content": {
          "type": "string",
          "description": "Content to write to the file"
        }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "list_files",
    "description": "List files and directories in a given path. Returns a listing with file types and sizes.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Directory path to list (absolute or relative to home)"
        },
        "recursive": {
          "type": "boolean",
          "description": "If true, list recursively (default: false)"
        }
      },
      "required": ["path"]
    }
  },
  {
    "name": "memory_search",
    "description": "Search through past conversation memories to find relevant context. Use this when the user refers to previous discussions, asks about past topics, or when you need context from earlier conversations. Returns summaries of relevant past conversations.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query - keywords or topics to search for in past conversations"
        },
        "max_results": {
          "type": "integer",
          "description": "Maximum number of memories to return (default: 3)"
        }
      },
      "required": ["query"]
    }
  }
]
EOF
}

# ============================================================================
# Security Helpers
# ============================================================================

ensure_command_whitelist_file() {
    local whitelist_dir
    whitelist_dir=$(dirname "$BASHOBOT_CMD_WHITELIST_FILE")
    mkdir -p "$whitelist_dir"
    if [[ ! -f "$BASHOBOT_CMD_WHITELIST_FILE" ]]; then
        touch "$BASHOBOT_CMD_WHITELIST_FILE"
        chmod 600 "$BASHOBOT_CMD_WHITELIST_FILE" 2>/dev/null || true
    fi
}

# Sanitize id for filesystem usage
sanitize_id() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

set_pending_approval() {
    local session_id="$1"
    local cmd="$2"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    mkdir -p "$BASHOBOT_CMD_APPROVAL_DIR"
    printf '%s' "$cmd" > "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
}

get_pending_approval() {
    local session_id="$1"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    if [[ -f "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id" ]]; then
        cat "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
    fi
}

clear_pending_approval() {
    local session_id="$1"
    local safe_id
    safe_id=$(sanitize_id "$session_id")
    rm -f "$BASHOBOT_CMD_APPROVAL_DIR/$safe_id"
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

# Resolve path to absolute, expanding ~ and checking allowed dirs
resolve_path() {
    local input_path="$1"
    local resolved
    
    # Expand ~ to home directory
    if [[ "$input_path" == "~"* ]]; then
        input_path="${HOME}${input_path:1}"
    fi
    
    # Make absolute if relative
    if [[ "$input_path" != /* ]]; then
        input_path="${HOME}/${input_path}"
    fi
    
    # Resolve to canonical path (without following symlinks for security)
    # Note: realpath -m allows non-existent paths
    if command -v realpath &>/dev/null; then
        resolved=$(realpath -m "$input_path" 2>/dev/null) || resolved="$input_path"
    else
        resolved="$input_path"
    fi
    
    echo "$resolved"
}

# Check if path is in allowed directories
check_path_allowed() {
    local path="$1"
    
    # If no restrictions, allow all
    if [[ -z "$BASHOBOT_ALLOWED_DIRS" ]]; then
        return 0
    fi
    
    local resolved
    resolved=$(resolve_path "$path")
    
    # Check against each allowed directory
    local IFS=','
    for allowed_dir in $BASHOBOT_ALLOWED_DIRS; do
        allowed_dir=$(resolve_path "$allowed_dir")
        if [[ "$resolved" == "$allowed_dir"* ]]; then
            return 0
        fi
    done
    
    return 1
}

# ============================================================================
# Tool Implementations
# ============================================================================

# Execute a bash command
tool_bash() {
    local command="$1"
    local working_dir="${2:-$HOME}"
    
    if [[ -z "$command" ]]; then
        echo '{"error": "No command provided"}'
        return 1
    fi
    
    if [[ "$BASHOBOT_CMD_WHITELIST_ENABLED" != "true" ]]; then
        log_info "Command whitelist disabled"
    else
        local cmd_name
        cmd_name=$(extract_command_name "$command")
        if [[ -z "$cmd_name" ]]; then
            echo '{"error": "Unable to determine command name"}'
            return 1
        fi

        if ! is_command_whitelisted "$cmd_name"; then
            local session_id="${CURRENT_SESSION_ID:-unknown}"
            local prompt
            prompt="The command $cmd_name is about to be executed for the first time, approve? <yes|no>"
            set_pending_approval "$session_id" "$cmd_name"
            jq -n \
                --arg prompt "$prompt" \
                --arg cmd "$cmd_name" \
                '{error: $prompt, approval_required: true, command: $cmd, prompt: $prompt}'
            return 1
        fi
    fi
    
    log_info "Tool bash: $command"
    
    # Resolve working directory
    working_dir=$(resolve_path "$working_dir")
    
    if [[ ! -d "$working_dir" ]]; then
        echo "{\"error\": \"Working directory does not exist: $working_dir\"}"
        return 1
    fi
    
    # Execute command with timeout
    local output exit_code
    output=$(cd "$working_dir" && timeout "$BASHOBOT_BASH_TIMEOUT" bash -c "$command" 2>&1)
    exit_code=$?
    
    # Truncate if too long
    if [[ ${#output} -gt $BASHOBOT_MAX_OUTPUT ]]; then
        output="${output:0:$BASHOBOT_MAX_OUTPUT}

[Output truncated at $BASHOBOT_MAX_OUTPUT bytes]"
    fi
    
    # Return result as JSON
    jq -n \
        --arg output "$output" \
        --argjson exit_code "$exit_code" \
        '{output: $output, exit_code: $exit_code}'
}

# Read a file
tool_read_file() {
    local path="$1"
    local offset="${2:-1}"
    local limit="${3:-500}"
    
    if [[ -z "$path" ]]; then
        echo '{"error": "No path provided"}'
        return 1
    fi
    
    path=$(resolve_path "$path")
    log_info "Tool read_file: $path (offset=$offset, limit=$limit)"
    
    # Check allowed directories
    if ! check_path_allowed "$path"; then
        echo "{\"error\": \"Path not in allowed directories: $path\"}"
        return 1
    fi
    
    if [[ ! -f "$path" ]]; then
        echo "{\"error\": \"File not found: $path\"}"
        return 1
    fi
    
    # Check if binary
    if file "$path" | grep -q "binary\|executable\|data"; then
        local size
        size=$(wc -c < "$path" | tr -d ' ')
        echo "{\"error\": \"Binary file ($size bytes): $path\"}"
        return 1
    fi
    
    # Read file with offset and limit
    local content total_lines
    total_lines=$(wc -l < "$path" | tr -d ' ')
    content=$(tail -n +"$offset" "$path" | head -n "$limit")
    
    local end_line=$((offset + limit - 1))
    [[ $end_line -gt $total_lines ]] && end_line=$total_lines
    
    jq -n \
        --arg content "$content" \
        --argjson total_lines "$total_lines" \
        --argjson start_line "$offset" \
        --argjson end_line "$end_line" \
        '{content: $content, total_lines: $total_lines, showing: {from: $start_line, to: $end_line}}'
}

# Write to a file
tool_write_file() {
    local path="$1"
    local content="$2"
    
    if [[ -z "$path" ]]; then
        echo '{"error": "No path provided"}'
        return 1
    fi
    
    path=$(resolve_path "$path")
    log_info "Tool write_file: $path (${#content} bytes)"
    
    # Check allowed directories
    if ! check_path_allowed "$path"; then
        echo "{\"error\": \"Path not in allowed directories: $path\"}"
        return 1
    fi
    
    # Create parent directories
    local dir
    dir=$(dirname "$path")
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "{\"error\": \"Failed to create directory: $dir\"}"
        return 1
    fi
    
    # Write file
    if ! printf '%s' "$content" > "$path" 2>/dev/null; then
        echo "{\"error\": \"Failed to write file: $path\"}"
        return 1
    fi
    
    local size
    size=$(wc -c < "$path" | tr -d ' ')
    
    jq -n \
        --arg path "$path" \
        --argjson bytes "$size" \
        '{success: true, path: $path, bytes_written: $bytes}'
}

# List files in a directory
tool_list_files() {
    local path="$1"
    local recursive="${2:-false}"
    
    if [[ -z "$path" ]]; then
        echo '{"error": "No path provided"}'
        return 1
    fi
    
    path=$(resolve_path "$path")
    log_info "Tool list_files: $path (recursive=$recursive)"
    
    # Check allowed directories
    if ! check_path_allowed "$path"; then
        echo "{\"error\": \"Path not in allowed directories: $path\"}"
        return 1
    fi
    
    if [[ ! -d "$path" ]]; then
        echo "{\"error\": \"Directory not found: $path\"}"
        return 1
    fi
    
    local listing
    if [[ "$recursive" == "true" ]]; then
        listing=$(find "$path" -maxdepth 3 -type f -o -type d 2>/dev/null | head -200)
    else
        listing=$(ls -la "$path" 2>/dev/null)
    fi
    
    jq -n \
        --arg path "$path" \
        --arg listing "$listing" \
        '{path: $path, listing: $listing}'
}

# Search conversation memories
tool_memory_search() {
    local query="$1"
    local max_results="${2:-3}"
    
    if [[ -z "$query" ]]; then
        echo '{"error": "No search query provided"}'
        return 1
    fi
    
    log_info "Tool memory_search: $query (max_results=$max_results)"
    
    # Check if memory system is available
    if ! type search_memories &>/dev/null; then
        echo '{"error": "Memory system not available"}'
        return 1
    fi
    
    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo '{"error": "Memory system is disabled"}'
        return 1
    fi
    
    local results
    results=$(search_memories "$query" "$max_results")
    
    local count
    count=$(echo "$results" | jq 'length')
    
    if [[ $count -eq 0 ]]; then
        jq -n \
            --arg query "$query" \
            '{
                query: $query,
                found: 0,
                message: "No relevant memories found for this query.",
                memories: []
            }'
    else
        # Format results for the LLM
        local formatted
        formatted=$(echo "$results" | jq '[.[] | {
            date: (.timestamp | split("T")[0]),
            topics: (.topics | join(", ")),
            summary: .summary,
            relevance_score: .relevance_score
        }]')
        
        jq -n \
            --arg query "$query" \
            --argjson count "$count" \
            --argjson memories "$formatted" \
            '{
                query: $query,
                found: $count,
                memories: $memories
            }'
    fi
}

# ============================================================================
# Tool Dispatcher
# ============================================================================

# Execute a tool by name with JSON arguments
# Returns: JSON result
execute_tool() {
    local tool_name="$1"
    local args_json="$2"
    
    if [[ "$BASHOBOT_TOOLS_ENABLED" != "true" ]]; then
        echo '{"error": "Tools are disabled"}'
        return 1
    fi
    
    case "$tool_name" in
        bash)
            local command working_dir
            command=$(echo "$args_json" | jq -r '.command // empty')
            working_dir=$(echo "$args_json" | jq -r '.working_dir // empty')
            tool_bash "$command" "$working_dir"
            ;;
        read_file)
            local path offset limit
            path=$(echo "$args_json" | jq -r '.path // empty')
            offset=$(echo "$args_json" | jq -r '.offset // 1')
            limit=$(echo "$args_json" | jq -r '.limit // 500')
            tool_read_file "$path" "$offset" "$limit"
            ;;
        write_file)
            local path content
            path=$(echo "$args_json" | jq -r '.path // empty')
            content=$(echo "$args_json" | jq -r '.content // empty')
            tool_write_file "$path" "$content"
            ;;
        list_files)
            local path recursive
            path=$(echo "$args_json" | jq -r '.path // empty')
            recursive=$(echo "$args_json" | jq -r '.recursive // false')
            tool_list_files "$path" "$recursive"
            ;;
        memory_search)
            local query max_results
            query=$(echo "$args_json" | jq -r '.query // empty')
            max_results=$(echo "$args_json" | jq -r '.max_results // 3')
            tool_memory_search "$query" "$max_results"
            ;;
        *)
            echo "{\"error\": \"Unknown tool: $tool_name\"}"
            return 1
            ;;
    esac
}

# ============================================================================
# Provider-specific Tool Formats
# ============================================================================

# Convert tools to Gemini format
get_tools_gemini() {
    if [[ "$BASHOBOT_TOOLS_ENABLED" != "true" ]]; then
        echo "null"
        return
    fi
    
    get_tools_definition | jq '[.[] | {
        name: .name,
        description: .description,
        parameters: .parameters
    }]'
}

# Convert tools to OpenAI format
get_tools_openai() {
    if [[ "$BASHOBOT_TOOLS_ENABLED" != "true" ]]; then
        echo "null"
        return
    fi
    
    get_tools_definition | jq '[.[] | {
        type: "function",
        function: {
            name: .name,
            description: .description,
            parameters: .parameters
        }
    }]'
}

# Convert tools to Claude format
get_tools_claude() {
    if [[ "$BASHOBOT_TOOLS_ENABLED" != "true" ]]; then
        echo "null"
        return
    fi
    
    get_tools_definition | jq '[.[] | {
        name: .name,
        description: .description,
        input_schema: .parameters
    }]'
}
