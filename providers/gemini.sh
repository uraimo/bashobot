#!/bin/bash
#
# Bashobot LLM Provider: Google Gemini
#
# Required env: GEMINI_API_KEY
#

GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models"

# Validate configuration
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "Error: GEMINI_API_KEY not set in config" >&2
    exit 1
fi

# Convert our message format to Gemini format
# Input: [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]
# Output: Gemini contents array
_convert_to_gemini_format() {
    local messages="$1"
    
    # Gemini uses "user" and "model" roles
    echo "$messages" | jq '[.[] | {
        role: (if .role == "assistant" then "model" else .role end),
        parts: [{ text: .content }]
    }]'
}

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    local gemini_contents
    
    gemini_contents=$(_convert_to_gemini_format "$messages")
    
    local request_body
    request_body=$(jq -n \
        --argjson contents "$gemini_contents" \
        --arg system "You are Bashobot, a helpful personal AI assistant. Be concise and helpful." \
        '{
            system_instruction: {
                parts: [{ text: $system }]
            },
            contents: $contents,
            generationConfig: {
                temperature: 0.7,
                maxOutputTokens: 2048
            }
        }')
    
    local response
    response=$(curl -s -X POST \
        "${GEMINI_API_URL}/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        --max-time 60)
    
    # Check for errors
    local error
    error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        log_error "Gemini API error: $error"
        echo "Error: $error"
        return 1
    fi
    
    # Extract text from response
    local text
    text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty')
    
    if [[ -z "$text" ]]; then
        log_error "No text in Gemini response: $response"
        echo "Sorry, I received an empty response."
        return 1
    fi
    
    echo "$text"
}

# Provider info
llm_info() {
    echo "Provider: Gemini"
    echo "Model: $GEMINI_MODEL"
}
