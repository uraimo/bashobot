#!/bin/bash
#
# Bashobot LLM Provider: Google Gemini (Subscription OAuth via Cloud Code Assist)
#
# Required auth: OAuth via ./bashobot.sh -login gemini-sub
#

GEMINI_SUB_MODEL="${GEMINI_SUB_MODEL:-gemini-2.5-flash}"
GEMINI_SUB_API_URL="https://cloudcode-pa.googleapis.com"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

_gemini_sub_get_creds() {
    local creds
    if ! creds=$(oauth_get_access_token "gemini-sub"); then
        echo "Error: Not logged in. Run ./bashobot.sh -login gemini-sub" >&2
        return 1
    fi
    echo "$creds"
}

models_list() {
    echo "Gemini subscription models use the same IDs as Google Gemini (example: gemini-2.5-flash)."
}

# Convert our message format to Gemini format
_convert_to_gemini_format() {
    local messages="$1"

    # Gemini uses "user" and "model" roles
    echo "$messages" | jq '[.[] | {
        role: (if .role == "assistant" then "model" else .role end),
        parts: [{ text: .content }]
    }]'
}

_gemini_sub_build_request() {
    local contents="$1"
    local tools="$2"
    local project_id="$3"

    local request_id
    request_id="pi-$(date +%s)-$(openssl rand -hex 4)"

    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --argjson tools "$tools" \
            --arg system "$(_get_system_prompt)" \
            --arg project "$project_id" \
            --arg model "$GEMINI_SUB_MODEL" \
            --arg request_id "$request_id" \
            '{
                project: $project,
                model: $model,
                request: {
                    contents: $contents,
                    systemInstruction: { parts: [{ text: $system }] },
                    generationConfig: { temperature: 0.7, maxOutputTokens: 8192 },
                    tools: [{ functionDeclarations: $tools }]
                },
                userAgent: "pi-coding-agent",
                requestId: $request_id
            }')
    else
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --arg system "$(_get_system_prompt)" \
            --arg project "$project_id" \
            --arg model "$GEMINI_SUB_MODEL" \
            --arg request_id "$request_id" \
            '{
                project: $project,
                model: $model,
                request: {
                    contents: $contents,
                    systemInstruction: { parts: [{ text: $system }] },
                    generationConfig: { temperature: 0.7, maxOutputTokens: 8192 }
                },
                userAgent: "pi-coding-agent",
                requestId: $request_id
            }')
    fi

    echo "$request_body"
}

_gemini_sub_send_request() {
    local request_body="$1"
    local token="$2"

    local tmp
    tmp=$(mktemp)

    local code
    code=$(curl -s -o "$tmp" -w "%{http_code}" -X POST \
        "${GEMINI_SUB_API_URL}/v1internal:streamGenerateContent?alt=sse" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: text/event-stream" \
        -H "User-Agent: google-cloud-sdk vscode_cloudshelleditor/0.1" \
        -H "X-Goog-Api-Client: gl-node/22.17.0" \
        -H "Client-Metadata: {\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}" \
        -d "$request_body" \
        --max-time 120)

    local response
    response=$(cat "$tmp")
    rm -f "$tmp"

    jq -n --arg code "$code" --arg response "$response" '{code: $code, response: $response}'
}

_gemini_sub_parse_sse() {
    local sse="$1"

    local data_lines
    data_lines=$(printf "%s" "$sse" | sed -n 's/^data: //p')

    if [[ -z "$data_lines" ]]; then
        echo "{}"
        return 0
    fi

    local aggregated
    aggregated=$(printf "%s\n" "$data_lines" | jq -s '
        reduce .[] as $chunk (
            {text: "", tool_calls: []};
            ($chunk.response.candidates[0].content.parts // []) as $parts
            | reduce $parts[] as $part (.;
                if ($part.text? != null) then
                    .text += $part.text
                elif ($part.functionCall? != null) then
                    .tool_calls += [ $part.functionCall ]
                else . end
            )
        )')

    echo "$aggregated"
}

_gemini_sub_pack_response() {
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
    local gemini_contents

    gemini_contents=$(_convert_to_gemini_format "$messages")

    # Get tools if available
    local tools="null"
    if [[ "$BASHOBOT_TOOLS_ENABLED" == "true" ]]; then
        tools=$(get_tools_gemini)
    fi

    local creds token project_id
    creds=$(_gemini_sub_get_creds) || return 1
    token=$(echo "$creds" | jq -r '.access // empty')
    project_id=$(echo "$creds" | jq -r '.projectId // empty')

    if [[ -z "$token" || -z "$project_id" ]]; then
        log_error "Gemini subscription credentials missing token or projectId"
        _gemini_sub_pack_response "Error: Missing OAuth credentials. Run ./bashobot.sh -login gemini-sub" "" ""
        return 1
    fi

    local iteration=0

    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))

        local api_request api_response response
        api_request=$(_gemini_sub_build_request "$gemini_contents" "$tools" "$project_id")
        api_response=$(_gemini_sub_send_request "$api_request" "$token")

        local code
        code=$(echo "$api_response" | jq -r '.code // empty')
        response=$(echo "$api_response" | jq -r '.response // empty')

        if [[ "$code" != "200" ]]; then
            local err
            err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null || true)
            log_error "Gemini subscription API error (HTTP $code): $err"
            _gemini_sub_pack_response "Error: ${err:-HTTP $code}" "$api_request" "$response"
            return 1
        fi

        local parsed
        parsed=$(_gemini_sub_parse_sse "$response")

        local tool_calls
        tool_calls=$(echo "$parsed" | jq -c '.tool_calls // []')

        if [[ "$tool_calls" != "[]" ]]; then
            local num_tools
            num_tools=$(echo "$tool_calls" | jq 'length')

            for ((i=0; i<num_tools; i++)); do
                local func_name func_args
                func_name=$(echo "$tool_calls" | jq -r ".[$i].name")
                func_args=$(echo "$tool_calls" | jq -c ".[$i].args")

                log_info "Tool call: $func_name with args: $func_args"

                local tool_result
                tool_result=$(tool_execute "$func_name" "$func_args")

                local approval_required
                approval_required=$(echo "$tool_result" | jq -r '.approval_required // empty' 2>/dev/null || true)
                if [[ "$approval_required" == "true" ]]; then
                    local prompt
                    prompt=$(echo "$tool_result" | jq -r '.prompt // .error // "Approval required"' 2>/dev/null)
                    _gemini_sub_pack_response "$prompt" "$api_request" "$response"
                    return 0
                fi

                log_info "Tool result: ${tool_result:0:200}..."

                # Add the function call and result to contents for next iteration
                gemini_contents=$(echo "$gemini_contents" | jq --arg name "$func_name" --argjson args "$func_args" '. + [{ role: "model", parts: [{ functionCall: { name: $name, args: $args } }] }]')

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
            done

            continue
        fi

        local text
        text=$(echo "$parsed" | jq -r '.text // empty')

        if [[ -z "$text" ]]; then
            log_error "No text in Gemini subscription response: $response"
            _gemini_sub_pack_response "Sorry, I received an empty response." "$api_request" "$response"
            return 1
        fi

        _gemini_sub_pack_response "$text" "$api_request" "$response"
        return 0
    done

    log_error "Max tool iterations reached"
    _gemini_sub_pack_response "Sorry, I made too many tool calls. Please try a simpler request." "" ""
    return 1
}

# Provider info
llm_info() {
    echo "Provider: Gemini (Subscription)"
    echo "Model: $GEMINI_SUB_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
