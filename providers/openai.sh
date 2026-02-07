#!/bin/bash
#
# Bashobot LLM Provider: OpenAI GPT
#
# Required env: OPENAI_API_KEY
#

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"
OPENAI_API_URL="https://api.openai.com/v1/chat/completions"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

# Validate configuration
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "Error: OPENAI_API_KEY not set in config" >&2
    exit 1
fi

# Build system prompt
_get_system_prompt() {
    local base="You are Bashobot, a helpful personal AI assistant. Be concise and helpful."
    
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]] && type get_tools_definition &>/dev/null; then
        echo "$base You have access to tools for executing bash commands and reading/writing files. Use them when appropriate to help the user."
    else
        echo "$base"
    fi
}

# Make a single API call to OpenAI
_openai_api_call() {
    local messages="$1"
    local tools="$2"
    
    # Prepend system message
    local full_messages
    full_messages=$(echo "$messages" | jq --arg system "$(_get_system_prompt)" \
        '[{"role": "system", "content": $system}] + .')
    
    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --argjson messages "$full_messages" \
            --argjson tools "$tools" \
            --arg model "$OPENAI_MODEL" \
            '{
                model: $model,
                max_tokens: 8192,
                temperature: 0.7,
                tools: $tools,
                messages: $messages
            }')
    else
        request_body=$(jq -n \
            --argjson messages "$full_messages" \
            --arg model "$OPENAI_MODEL" \
            '{
                model: $model,
                max_tokens: 8192,
                temperature: 0.7,
                messages: $messages
            }')
    fi
    
    curl -s -X POST "$OPENAI_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$request_body" \
        --max-time 120
}

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    
    # Get tools if available
    local tools="null"
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]] && type get_tools_openai &>/dev/null; then
        tools=$(get_tools_openai)
    fi
    
    local iteration=0
    local current_messages="$messages"
    
    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))
        
        local response
        response=$(_openai_api_call "$current_messages" "$tools")
        
        # Check for errors
        local error
        error=$(echo "$response" | jq -r '.error.message // empty')
        if [[ -n "$error" ]]; then
            log_error "OpenAI API error: $error"
            echo "Error: $error"
            return 1
        fi
        
        # Get the message
        local message
        message=$(echo "$response" | jq -c '.choices[0].message')
        
        # Check for tool calls
        local tool_calls
        tool_calls=$(echo "$message" | jq -c '.tool_calls // empty')
        
        if [[ -n "$tool_calls" ]] && [[ "$tool_calls" != "null" ]]; then
            # Add assistant message with tool calls to conversation
            current_messages=$(echo "$current_messages" | jq --argjson msg "$message" '. + [$msg]')
            
            # Process each tool call
            local num_tools
            num_tools=$(echo "$tool_calls" | jq 'length')
            
            for ((i=0; i<num_tools; i++)); do
                local tool_id tool_name tool_args
                tool_id=$(echo "$tool_calls" | jq -r ".[$i].id")
                tool_name=$(echo "$tool_calls" | jq -r ".[$i].function.name")
                tool_args=$(echo "$tool_calls" | jq -c ".[$i].function.arguments")
                
                # OpenAI returns arguments as a JSON string, need to parse it
                tool_args=$(echo "$tool_args" | jq -r '.')
                
                log_info "Tool call: $tool_name (id: $tool_id) with args: $tool_args"
                
                # Execute the tool
                local tool_result
                if type execute_tool &>/dev/null; then
                    tool_result=$(execute_tool "$tool_name" "$tool_args")
                else
                    tool_result='{"error": "Tools not available"}'
                fi
                
                log_info "Tool result: ${tool_result:0:200}..."
                
                # Add tool result message
                current_messages=$(echo "$current_messages" | jq \
                    --arg id "$tool_id" \
                    --arg result "$tool_result" \
                    '. + [{
                        "role": "tool",
                        "tool_call_id": $id,
                        "content": $result
                    }]')
            done
            
            continue
        fi
        
        # No tool calls, extract text response
        local text
        text=$(echo "$message" | jq -r '.content // empty')
        
        if [[ -z "$text" ]]; then
            log_error "No text in OpenAI response: $response"
            echo "Sorry, I received an empty response."
            return 1
        fi
        
        echo "$text"
        return 0
    done
    
    log_error "Max tool iterations reached"
    echo "Sorry, I made too many tool calls. Please try a simpler request."
    return 1
}

# Provider info
llm_info() {
    echo "Provider: OpenAI"
    echo "Model: $OPENAI_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
