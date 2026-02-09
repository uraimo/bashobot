#!/bin/bash
#
# Bashobot LLM Provider: Anthropic Claude
#
# Required env: ANTHROPIC_API_KEY
#

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
CLAUDE_API_URL="https://api.anthropic.com/v1/messages"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

# Validate configuration
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Error: ANTHROPIC_API_KEY not set in config" >&2
    exit 1
fi

models_list() {
    local code body
    _models_http_get "https://api.anthropic.com/v1/models" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01"
    code="$MODELS_HTTP_CODE"
    body="$MODELS_HTTP_BODY"

    if [[ "$code" != "200" ]]; then
        local err
        err=$(echo "$body" | jq -r '.error.message // empty' 2>/dev/null || true)
        echo "Claude: failed to list models (HTTP $code)${err:+: $err}"
        return 0
    fi

    local models
    models=$(echo "$body" | jq -r '.data[].id // .models[].id // empty' 2>/dev/null | sort -u)
    if [[ -z "$models" ]]; then
        echo "Claude: no models found"
        return 0
    fi

    echo "Claude models:"
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        echo "  - $m"
    done <<< "$models"
}

# Build system prompt
_get_system_prompt() {
    local base
    local soul_file="$BASHOBOT_DIR/SOUL.md"
    
    if [[ -f "$soul_file" ]]; then
        base=$(cat "$soul_file")
    else
        base="You are Bashobot, a helpful personal AI assistant. Be concise and helpful."
    fi
    
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]]; then
        echo "$base You have access to tools for executing bash commands and reading/writing files. Use them when appropriate to help the user."
    else
        echo "$base"
    fi
}

_claude_build_request() {
    local messages="$1"
    local tools="$2"
    
    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --argjson messages "$messages" \
            --argjson tools "$tools" \
            --arg model "$CLAUDE_MODEL" \
            --arg system "$(_get_system_prompt)" \
            '{
                model: $model,
                max_tokens: 8192,
                system: $system,
                tools: $tools,
                messages: $messages
            }')
    else
        request_body=$(jq -n \
            --argjson messages "$messages" \
            --arg model "$CLAUDE_MODEL" \
            --arg system "$(_get_system_prompt)" \
            '{
                model: $model,
                max_tokens: 8192,
                system: $system,
                messages: $messages
            }')
    fi
    echo "$request_body"
}

_claude_send_request() {
    local request_body="$1"

    local response
    response=$(curl -s -X POST "$CLAUDE_API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$request_body" \
        --max-time 120)
    jq -n --arg request "$request_body" --arg response "$response" '{request: $request, response: $response}'
}

# Make a single API call to Claude
_claude_api_call() {
    local messages="$1"
    local tools="$2"

    local request_body
    request_body=$(_claude_build_request "$messages" "$tools")
    _claude_send_request "$request_body"
}

_claude_pack_response() {
    local text="$1"
    local request="$2"
    local response="$3"

    jq -n --arg text "$text" --arg request "$request" --arg response "$response" \
        '{text: $text, request: $request, response: $response}'
}

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    
    # Get tools if available
    local tools="null"
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]]; then
        tools=$(get_tools_claude)
    fi
    
    local iteration=0
    local current_messages="$messages"
    
    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))
        
        local response
        local api_result api_request api_response
        api_result=$(_claude_api_call "$current_messages" "$tools")
        api_request=$(echo "$api_result" | jq -r '.request // empty')
        api_response=$(echo "$api_result" | jq -r '.response // empty')
        response="$api_response"
        
        # Check for errors
        local error
        error=$(echo "$response" | jq -r '.error.message // empty')
        if [[ -n "$error" ]]; then
            log_error "Claude API error: $error"
            _claude_pack_response "Error: $error" "$api_request" "$api_response"
            return 1
        fi
        
        # Check stop reason
        local stop_reason
        stop_reason=$(echo "$response" | jq -r '.stop_reason // empty')
        
        if [[ "$stop_reason" == "tool_use" ]]; then
            # Extract tool calls from content
            local tool_uses
            tool_uses=$(echo "$response" | jq -c '[.content[] | select(.type == "tool_use")]')
            
            if [[ "$tool_uses" == "[]" ]]; then
                log_error "tool_use stop reason but no tool calls found"
                break
            fi
            
            # Add assistant message with tool use to conversation
            local assistant_content
            assistant_content=$(echo "$response" | jq -c '.content')
            current_messages=$(echo "$current_messages" | jq --argjson content "$assistant_content" \
                '. + [{"role": "assistant", "content": $content}]')
            
            # Process each tool call and collect results
            local tool_results="[]"
            local num_tools
            num_tools=$(echo "$tool_uses" | jq 'length')
            
            for ((i=0; i<num_tools; i++)); do
                local tool_id tool_name tool_input
                tool_id=$(echo "$tool_uses" | jq -r ".[$i].id")
                tool_name=$(echo "$tool_uses" | jq -r ".[$i].name")
                tool_input=$(echo "$tool_uses" | jq -c ".[$i].input")
                
                log_info "Tool call: $tool_name (id: $tool_id) with args: $tool_input"
                
                # Execute the tool
                local tool_result
                tool_result=$(tool_execute "$tool_name" "$tool_input")
                
                local approval_required
                approval_required=$(echo "$tool_result" | jq -r '.approval_required // empty' 2>/dev/null || true)
                if [[ "$approval_required" == "true" ]]; then
                    local prompt
                    prompt=$(echo "$tool_result" | jq -r '.prompt // .error // "Approval required"' 2>/dev/null)
                    _claude_pack_response "$prompt" "$api_request" "$api_response"
                    return 0
                fi

                log_info "Tool result: ${tool_result:0:200}..."
                
                # Add to results array
                tool_results=$(echo "$tool_results" | jq \
                    --arg id "$tool_id" \
                    --arg result "$tool_result" \
                    '. + [{
                        "type": "tool_result",
                        "tool_use_id": $id,
                        "content": $result
                    }]')
            done
            
            # Add user message with tool results
            current_messages=$(echo "$current_messages" | jq --argjson results "$tool_results" \
                '. + [{"role": "user", "content": $results}]')
            
            continue
        fi
        
        # No tool use, extract text response
        local text
        text=$(echo "$response" | jq -r '[.content[] | select(.type == "text") | .text] | join("")')
        
        if [[ -z "$text" ]]; then
            log_error "No text in Claude response: $response"
            _claude_pack_response "Sorry, I received an empty response." "$api_request" "$api_response"
            return 1
        fi
        
        _claude_pack_response "$text" "$api_request" "$api_response"
        return 0
    done
    
    log_error "Max tool iterations reached"
    _claude_pack_response "Sorry, I made too many tool calls. Please try a simpler request." "$api_request" "$api_response"
    return 1
}

# Provider info
llm_info() {
    echo "Provider: Claude"
    echo "Model: $CLAUDE_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
