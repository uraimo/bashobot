#!/bin/bash
#
# Bashobot LLM Provider: OpenAI Codex (ChatGPT Subscription OAuth)
#
# Required auth: OAuth via ./bashobot.sh -login openai-sub
#

OPENAI_SUB_MODEL="${OPENAI_SUB_MODEL:-gpt-5.1-codex}"
OPENAI_SUB_API_URL="https://chatgpt.com/backend-api/codex/responses"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

_openai_sub_get_creds() {
    local creds
    if ! creds=$(oauth_get_access_token "openai-sub"); then
        echo "Error: Not logged in. Run ./bashobot.sh -login openai-sub" >&2
        return 1
    fi
    echo "$creds"
}

models_list() {
    echo "OpenAI subscription models use Codex IDs (example: gpt-5.1-codex)."
}

_openai_sub_convert_messages() {
    local messages="$1"

    echo "$messages" | jq -c '
        to_entries | map(
            if .value.role == "user" then
                {
                    role: "user",
                    content: [{ type: "input_text", text: (.value.content | tostring) }]
                }
            elif .value.role == "assistant" then
                {
                    type: "message",
                    role: "assistant",
                    status: "completed",
                    id: ("msg_" + (.key | tostring)),
                    content: [{ type: "output_text", text: (.value.content | tostring), annotations: [] }]
                }
            elif .value.role == "tool" then
                {
                    type: "function_call_output",
                    call_id: (.value.tool_call_id // ("call_" + (.key | tostring))),
                    output: (.value.content | tostring)
                }
            else empty end
        )
    '
}

_openai_sub_build_request() {
    local input_json="$1"
    local tools="$2"

    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --arg model "$OPENAI_SUB_MODEL" \
            --arg instructions "$(_get_system_prompt)" \
            --argjson input "$input_json" \
            --argjson tools "$tools" \
            '{
                model: $model,
                instructions: $instructions,
                input: $input,
                store: false,
                stream: false,
                text: { verbosity: "medium" },
                include: ["reasoning.encrypted_content"],
                tool_choice: "auto",
                parallel_tool_calls: true,
                tools: $tools
            }')
    else
        request_body=$(jq -n \
            --arg model "$OPENAI_SUB_MODEL" \
            --arg instructions "$(_get_system_prompt)" \
            --argjson input "$input_json" \
            '{
                model: $model,
                instructions: $instructions,
                input: $input,
                store: false,
                stream: false,
                text: { verbosity: "medium" },
                include: ["reasoning.encrypted_content"]
            }')
    fi

    echo "$request_body"
}

_openai_sub_send_request() {
    local request_body="$1"
    local token="$2"
    local account_id="$3"

    local response
    response=$(curl -s -X POST "$OPENAI_SUB_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "chatgpt-account-id: $account_id" \
        -H "OpenAI-Beta: responses=experimental" \
        -H "originator: pi" \
        -H "User-Agent: bashobot/1.0" \
        -d "$request_body" \
        --max-time 120)
    jq -n --arg request "$request_body" --arg response "$response" '{request: $request, response: $response}'
}

_openai_sub_pack_response() {
    local text="$1"
    local request="$2"
    local response="$3"

    jq -n --arg text "$text" --arg request "$request" --arg response "$response" \
        '{text: $text, request: $request, response: $response}'
}

_openai_sub_extract_tool_calls() {
    local response="$1"

    echo "$response" | jq -c '
        [
            (.output // [])[]
            | select(.type == "function_call" or .type == "tool_call")
            | {
                id: (.call_id // .id // ""),
                name: (.name // .function?.name // ""),
                arguments: (try (.arguments | fromjson) catch .arguments // {})
            }
        ]
    '
}

_openai_sub_extract_text() {
    local response="$1"

    echo "$response" | jq -r '[
        (.output // [])[]
        | select(.type == "message" and (.role // "assistant") == "assistant")
        | (.content // [])[]?
        | select(.type == "output_text")
        | .text
    ] | join("")'
}

# Main chat function - called by bashobot core
# Args: messages (JSON array of {role, content})
# Returns: assistant response text
llm_chat() {
    local messages="$1"

    local input_json
    input_json=$(_openai_sub_convert_messages "$messages")

    # Get tools if available
    local tools="null"
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]]; then
        tools=$(get_tools_openai)
    fi

    local creds token account_id
    creds=$(_openai_sub_get_creds) || return 1
    token=$(echo "$creds" | jq -r '.access // empty')
    account_id=$(echo "$creds" | jq -r '.accountId // empty')

    if [[ -z "$token" ]]; then
        _openai_sub_pack_response "Error: Missing OAuth token. Run ./bashobot.sh -login openai-sub" "" ""
        return 1
    fi

    if [[ -z "$account_id" ]]; then
        account_id=$(oauth_extract_openai_account_id "$token")
    fi

    if [[ -z "$account_id" ]]; then
        _openai_sub_pack_response "Error: Missing account ID in OAuth token." "" ""
        return 1
    fi

    local iteration=0

    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))

        local api_request api_response response
        api_request=$(_openai_sub_build_request "$input_json" "$tools")
        api_response=$(_openai_sub_send_request "$api_request" "$token" "$account_id")
        response=$(echo "$api_response" | jq -r '.response // empty')

        local error
        error=$(echo "$response" | jq -r '.error.message // .error // empty' 2>/dev/null || true)
        if [[ -n "$error" ]]; then
            log_error "OpenAI subscription API error: $error"
            _openai_sub_pack_response "Error: $error" "$api_request" "$response"
            return 1
        fi

        local tool_calls
        tool_calls=$(_openai_sub_extract_tool_calls "$response")

        if [[ "$tool_calls" != "[]" ]]; then
            local num_tools
            num_tools=$(echo "$tool_calls" | jq 'length')

            for ((i=0; i<num_tools; i++)); do
                local tool_id tool_name tool_args
                tool_id=$(echo "$tool_calls" | jq -r ".[$i].id")
                tool_name=$(echo "$tool_calls" | jq -r ".[$i].name")
                tool_args=$(echo "$tool_calls" | jq -c ".[$i].arguments")

                if [[ -z "$tool_id" ]]; then
                    tool_id="call_${tool_name}_$RANDOM"
                fi

                log_info "Tool call: $tool_name (id: $tool_id) with args: $tool_args"

                # Add function_call to input history
                input_json=$(echo "$input_json" | jq \
                    --arg id "$tool_id" \
                    --arg name "$tool_name" \
                    --arg args "$tool_args" \
                    '. + [{
                        type: "function_call",
                        call_id: $id,
                        name: $name,
                        arguments: $args
                    }]')

                # Execute the tool
                local tool_result
                tool_result=$(tool_execute "$tool_name" "$tool_args")

                local approval_required
                approval_required=$(echo "$tool_result" | jq -r '.approval_required // empty' 2>/dev/null || true)
                if [[ "$approval_required" == "true" ]]; then
                    local prompt
                    prompt=$(echo "$tool_result" | jq -r '.prompt // .error // "Approval required"' 2>/dev/null)
                    _openai_sub_pack_response "$prompt" "$api_request" "$response"
                    return 0
                fi

                log_info "Tool result: ${tool_result:0:200}..."

                input_json=$(echo "$input_json" | jq \
                    --arg id "$tool_id" \
                    --arg output "$tool_result" \
                    '. + [{
                        type: "function_call_output",
                        call_id: $id,
                        output: $output
                    }]')
            done

            continue
        fi

        local text
        text=$(_openai_sub_extract_text "$response")

        if [[ -z "$text" ]]; then
            log_error "No text in OpenAI subscription response: $response"
            _openai_sub_pack_response "Sorry, I received an empty response." "$api_request" "$response"
            return 1
        fi

        _openai_sub_pack_response "$text" "$api_request" "$response"
        return 0
    done

    log_error "Max tool iterations reached"
    _openai_sub_pack_response "Sorry, I made too many tool calls. Please try a simpler request." "" ""
    return 1
}

# Provider info
llm_info() {
    echo "Provider: OpenAI Codex (Subscription)"
    echo "Model: $OPENAI_SUB_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
