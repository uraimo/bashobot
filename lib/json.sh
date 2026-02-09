#!/bin/bash
#
# Bashobot JSON Helpers
#

json_append_message() {
    local session_file="$1"
    local role="$2"
    local content="$3"

    jq --arg role "$role" --arg content "$content" \
        '.messages += [{"role": $role, "content": $content}]' \
        "$session_file" > "${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
}

json_get_messages() {
    local session_file="$1"
    jq -c '.messages' "$session_file"
}

json_append_llm_log() {
    local session_file="$1"
    local log_object="$2"

    jq \
        --argjson entry "$log_object" \
        '.llm_log = (.llm_log // []) + [$entry]' \
        "$session_file" > "${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
}
