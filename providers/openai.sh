#!/bin/bash
#
# Bashobot LLM Provider: OpenAI GPT
#
# Required env: OPENAI_API_KEY
#

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"
OPENAI_API_URL="https://api.openai.com/v1/chat/completions"

# Validate configuration
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "Error: OPENAI_API_KEY not set in config" >&2
    exit 1
fi

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    
    # Prepend system message
    local full_messages
    full_messages=$(echo "$messages" | jq '[
        {"role": "system", "content": "You are Bashobot, a helpful personal AI assistant. Be concise and helpful."}
    ] + .')
    
    local request_body
    request_body=$(jq -n \
        --argjson messages "$full_messages" \
        --arg model "$OPENAI_MODEL" \
        '{
            model: $model,
            max_tokens: 2048,
            temperature: 0.7,
            messages: $messages
        }')
    
    local response
    response=$(curl -s -X POST "$OPENAI_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$request_body" \
        --max-time 60)
    
    # Check for errors
    local error
    error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        log_error "OpenAI API error: $error"
        echo "Error: $error"
        return 1
    fi
    
    # Extract text from response
    local text
    text=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$text" ]]; then
        log_error "No text in OpenAI response: $response"
        echo "Sorry, I received an empty response."
        return 1
    fi
    
    echo "$text"
}

# Provider info
llm_info() {
    echo "Provider: OpenAI"
    echo "Model: $OPENAI_MODEL"
}
