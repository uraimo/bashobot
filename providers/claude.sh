#!/bin/bash
#
# Bashobot LLM Provider: Anthropic Claude
#
# Required env: ANTHROPIC_API_KEY
#

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
CLAUDE_API_URL="https://api.anthropic.com/v1/messages"

# Validate configuration
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Error: ANTHROPIC_API_KEY not set in config" >&2
    exit 1
fi

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    
    local request_body
    request_body=$(jq -n \
        --argjson messages "$messages" \
        --arg model "$CLAUDE_MODEL" \
        --arg system "You are Bashobot, a helpful personal AI assistant. Be concise and helpful." \
        '{
            model: $model,
            max_tokens: 2048,
            system: $system,
            messages: $messages
        }')
    
    local response
    response=$(curl -s -X POST "$CLAUDE_API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$request_body" \
        --max-time 60)
    
    # Check for errors
    local error
    error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        log_error "Claude API error: $error"
        echo "Error: $error"
        return 1
    fi
    
    # Extract text from response
    local text
    text=$(echo "$response" | jq -r '.content[0].text // empty')
    
    if [[ -z "$text" ]]; then
        log_error "No text in Claude response: $response"
        echo "Sorry, I received an empty response."
        return 1
    fi
    
    echo "$text"
}

# Provider info
llm_info() {
    echo "Provider: Claude"
    echo "Model: $CLAUDE_MODEL"
}
