#!/bin/bash
#
# Bashobot LLM Provider: Antigravity (Subscription OAuth via Google Cloud)
#
# Required auth: OAuth via ./bashobot.sh -login antigravity-sub
#

ANTIGRAVITY_SUB_MODEL="${ANTIGRAVITY_SUB_MODEL:-gemini-3-pro}"
ANTIGRAVITY_SUB_PRIMARY_URL="https://daily-cloudcode-pa.sandbox.googleapis.com"
ANTIGRAVITY_SUB_FALLBACK_URL="https://cloudcode-pa.googleapis.com"

# Maximum tool call iterations to prevent infinite loops
MAX_TOOL_ITERATIONS=10

_antigravity_sub_get_creds() {
    local creds
    if ! creds=$(oauth_get_access_token "antigravity-sub"); then
        echo "Error: Not logged in. Run ./bashobot.sh -login antigravity-sub" >&2
        return 1
    fi
    echo "$creds"
}

models_list() {
    echo "Antigravity subscription models include Gemini 3, Claude, and GPT-OSS variants." 
    echo "Set the model explicitly with /model antigravity-sub <model-id>."
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

_antigravity_sub_build_request() {
    local contents="$1"
    local tools="$2"
    local project_id="$3"

    local request_id
    request_id="agent-$(date +%s)-$(openssl rand -hex 4)"

    local request_body
    if [[ "$tools" != "null" ]] && [[ -n "$tools" ]]; then
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --argjson tools "$tools" \
            --arg system "$(_get_system_prompt)" \
            --arg project "$project_id" \
            --arg model "$ANTIGRAVITY_SUB_MODEL" \
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
                requestType: "agent",
                userAgent: "antigravity",
                requestId: $request_id
            }')
    else
        request_body=$(jq -n \
            --argjson contents "$contents" \
            --arg system "$(_get_system_prompt)" \
            --arg project "$project_id" \
            --arg model "$ANTIGRAVITY_SUB_MODEL" \
            --arg request_id "$request_id" \
            '{
                project: $project,
                model: $model,
                request: {
                    contents: $contents,
                    systemInstruction: { parts: [{ text: $system }] },
                    generationConfig: { temperature: 0.7, maxOutputTokens: 8192 }
                },
                requestType: "agent",
                userAgent: "antigravity",
                requestId: $request_id
            }')
    fi

    echo "$request_body"
}

_antigravity_sub_send_request() {
    local base_url="$1"
    local request_body="$2"
    local token="$3"

    local tmp
    tmp=$(mktemp)

    local code
    code=$(curl -s -o "$tmp" -w "%{http_code}" -X POST \
        "${base_url}/v1internal:streamGenerateContent?alt=sse" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: text/event-stream" \
        -H "User-Agent: antigravity/1.15.8 darwin/arm64" \
        -H "X-Goog-Api-Client: google-cloud-sdk vscode_cloudshelleditor/0.1" \
        -H "Client-Metadata: {\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}" \
        -d "$request_body" \
        --max-time 120)

    local response
    response=$(cat "$tmp")
    rm -f "$tmp"

    jq -n --arg code "$code" --arg response "$response" '{code: $code, response: $response}'
}

_antigravity_sub_parse_sse() {
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

_antigravity_sub_pack_response() {
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
    creds=$(_antigravity_sub_get_creds) || return 1
    token=$(echo "$creds" | jq -r '.access // empty')
    project_id=$(echo "$creds" | jq -r '.projectId // empty')

    if [[ -z "$token" || -z "$project_id" ]]; then
        log_error "Antigravity subscription credentials missing token or projectId"
        _antigravity_sub_pack_response "Error: Missing OAuth credentials. Run ./bashobot.sh -login antigravity-sub" "" ""
        return 1
    fi

    local iteration=0

    while [[ $iteration -lt $MAX_TOOL_ITERATIONS ]]; do
        iteration=$((iteration + 1))

        local api_request api_response response
        api_request=$(_antigravity_sub_build_request "$gemini_contents" "$tools" "$project_id")

        api_response=$(_antigravity_sub_send_request "$ANTIGRAVITY_SUB_PRIMARY_URL" "$api_request" "$token")
        local code
        code=$(echo "$api_response" | jq -r '.code // empty')

        if [[ "$code" != "200" ]]; then
            api_response=$(_antigravity_sub_send_request "$ANTIGRAVITY_SUB_FALLBACK_URL" "$api_request" "$token")
            code=$(echo "$api_response" | jq -r '.code // empty')
        fi

        response=$(echo "$api_response" | jq -r '.response // empty')

        if [[ "$code" != "200" ]]; then
            local err
            err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null || true)
            log_error "Antigravity API error (HTTP $code): $err"
            _antigravity_sub_pack_response "Error: ${err:-HTTP $code}" "$api_request" "$response"
            return 1
        fi

        local parsed
        parsed=$(_antigravity_sub_parse_sse "$response")

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
                    _antigravity_sub_pack_response "$prompt" "$api_request" "$response"
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
            log_error "No text in Antigravity response: $response"
            _antigravity_sub_pack_response "Sorry, I received an empty response." "$api_request" "$response"
            return 1
        fi

        _antigravity_sub_pack_response "$text" "$api_request" "$response"
        return 0
    done

    log_error "Max tool iterations reached"
    _antigravity_sub_pack_response "Sorry, I made too many tool calls. Please try a simpler request." "" ""
    return 1
}

# Provider info
llm_info() {
    echo "Provider: Antigravity (Subscription)"
    echo "Model: $ANTIGRAVITY_SUB_MODEL"
    echo "Tools: $BASHOBOT_TOOLS_ENABLED"
}
