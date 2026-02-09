#!/bin/bash
#
# Bashobot LLM Provider: Google Gemini
#
# Required env: GEMINI_API_KEY
#

GEMINI_MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

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

# Build system prompt
_get_system_prompt() {
    local base
    local soul_file="$BASHOBOT_DIR/SOUL.md"
    
    if [[ -f "$soul_file" ]]; then
        base=$(cat "$soul_file")
    else
        base="You are Bashobot, a helpful personal AI assistant. Be concise and helpful."
    fi
    
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]] && type get_tools_definition &>/dev/null; then
        echo "$base You have access to tools for executing bash commands and reading/writing files. Use them when appropriate to help the user."
    else
        echo "$base"
    fi
}

# Make a single API call to Gemini
_gemini_api_call() {
    local contents="$1"
    local tools="$2"
    
    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --argjson tools "$tools" \
            --arg system "$(_get_system_prompt)" \
            '{
                system_instruction: {
                    parts: [{ text: $system }]
                },
                contents: $contents,
                tools: [{ functionDeclarations: $tools }],
                generationConfig: {
                    temperature: 0.7,
                    maxOutputTokens: 8192
                }
            }')
    else
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --arg system "$(_get_system_prompt)" \
            '{
                system_instruction: {
                    parts: [{ text: $system }]
                },
                contents: $contents,
                generationConfig: {
                    temperature: 0.7,
                    maxOutputTokens: 8192
                }
            }')
    fi
    
    LLM_LAST_REQUEST="$request_body"
    local response
    response=$(curl -s -X POST \
        "${GEMINI_API_URL}/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        --max-time 120)
    LLM_LAST_RESPONSE="$response"
    echo "$response"
}

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"
    local gemini_contents
    
    gemini_contents=$(_convert_to_gemini_format "$messages")
    
    # Get tools if available
    local tools="null"
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]] && type get_tools_gemini &>/dev/null; then
        tools=$(get_tools_gemini)
    fi
    
    local iteration=0
    local final_text=""
    
    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))
        
        local response
        response=$(_gemini_api_call "$gemini_contents" "$tools")
        
        # Check for errors
        local error
        error=$(echo "$response" | jq -r '.error.message // empty')
        if [[ -n "$error" ]]; then
            log_error "Gemini API error: $error"
            echo "Error: $error"
            return 1
        fi
        
        # Check if we have a function call
        local function_call
        function_call=$(echo "$response" | jq -r '.candidates[0].content.parts[0].functionCall // empty')
        
        if [[ -n "$function_call" ]] && [[ "$function_call" != "null" ]]; then
            # Extract function name and args
            local func_name func_args
            func_name=$(echo "$response" | jq -r '.candidates[0].content.parts[0].functionCall.name')
            func_args=$(echo "$response" | jq -c '.candidates[0].content.parts[0].functionCall.args')
            
            log_info "Tool call: $func_name with args: $func_args"
            
            # Execute the tool
            local tool_result
            if type execute_tool &>/dev/null; then
                tool_result=$(execute_tool "$func_name" "$func_args")
            else
                tool_result='{"error": "Tools not available"}'
            fi
            
            local approval_required
            approval_required=$(echo "$tool_result" | jq -r '.approval_required // empty' 2>/dev/null || true)
            if [[ "$approval_required" == "true" ]]; then
                local prompt
                prompt=$(echo "$tool_result" | jq -r '.prompt // .error // "Approval required"' 2>/dev/null)
                echo "$prompt"
                return 0
            fi

            log_info "Tool result: ${tool_result:0:200}..."
            
            # Add the function call and result to contents for next iteration
            # First, add the model's function call response
            gemini_contents=$(echo "$gemini_contents" | jq --argjson fc "$(echo "$response" | jq '.candidates[0].content')" '. + [$fc]')
            
            # Then add the function result
            gemini_contents=$(echo "$gemini_contents" | jq \
                --arg name "$func_name" \
                --argjson result "$tool_result" \
                '. + [{
                    role: "user",
                    parts: [{
                        functionResponse: {
                            name: $name,
                            response: $result
                        }
                    }]
                }]')
            
            continue
        fi
        
        # No function call, extract text response
        local text
        text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty')
        
        if [[ -z "$text" ]]; then
            # Check for other parts (might have multiple)
            text=$(echo "$response" | jq -r '[.candidates[0].content.parts[] | .text // empty] | join("")')
        fi
        
        if [[ -z "$text" ]]; then
            log_error "No text in Gemini response: $response"
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
    echo "Provider: Gemini"
    echo "Model: $GEMINI_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
