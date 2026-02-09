#!/bin/bash
#
# Bashobot Session Management
#
# Handles context window limits and auto-summarization
#

# ============================================================================
# Configuration
# ============================================================================

# Approximate token limits (conservative estimates)
# Most models have 100k+ context now
MAX_CONTEXT_TOKENS="${MAX_CONTEXT_TOKENS:-110000}"    # Trigger summarization at this point
KEEP_RECENT_TOKENS="${KEEP_RECENT_TOKENS:-2000}"      # Keep this many tokens of recent messages
SUMMARY_MAX_TOKENS="${SUMMARY_MAX_TOKENS:-500}"        # Target size for summaries

# Rough chars-to-tokens ratio (conservative: ~3.5 chars per token for English)
CHARS_PER_TOKEN=4

# ============================================================================
# Token Estimation
# ============================================================================

# Estimate token count from text
# This is a rough approximation - actual tokenization varies by model
estimate_tokens() {
    local text="$1"
    local char_count=${#text}
    echo $(( (char_count + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN ))
}

# Estimate tokens in a messages array
estimate_messages_tokens() {
    local messages="$1"
    local total_chars
    
    # Sum up all content lengths plus some overhead for JSON structure
    total_chars=$(echo "$messages" | jq -r '[.[] | .content | length] | add // 0')
    local message_count
    message_count=$(echo "$messages" | jq 'length')
    
    # Add ~20 tokens overhead per message for role, formatting, etc.
    local overhead=$(( message_count * 20 ))
    local content_tokens=$(( (total_chars + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN ))
    
    echo $(( content_tokens + overhead ))
}

# ============================================================================
# Session Structure
# ============================================================================

# Session JSON structure:
# {
#   "summary": "Previous conversation summary...",  (optional)
#   "summary_message_count": 15,                    (how many messages were summarized)
#   "messages": [
#     {"role": "user", "content": "..."},
#     {"role": "assistant", "content": "..."}
#   ]
# }

# Get messages for LLM (includes summary if present)
get_messages_for_llm() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    local has_summary
    has_summary=$(jq -r '.summary // empty' "$session_file")
    
    if [[ -n "$has_summary" ]]; then
        # Prepend summary as a system-style user message
        jq '[{
            role: "user", 
            content: ("Previous conversation summary:\n" + .summary + "\n\n(This summarizes our earlier discussion. Continue from here.)")
        }, {
            role: "assistant",
            content: "I understand. I have context from our previous conversation. How can I help you?"
        }] + .messages' "$session_file"
    else
        jq -c '.messages' "$session_file"
    fi
}

# Get raw messages (without summary injection)
get_raw_messages() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    jq -c '.messages' "$session_file"
}

# Get session stats
get_session_stats() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    local message_count summary_count total_tokens has_summary
    message_count=$(jq '.messages | length' "$session_file")
    summary_count=$(jq '.summary_message_count // 0' "$session_file")
    has_summary=$(jq -r 'if .summary then "yes" else "no" end' "$session_file")
    
    local messages
    messages=$(get_messages_for_llm "$session_id")
    total_tokens=$(estimate_messages_tokens "$messages")
    
    echo "Messages in context: $message_count"
    echo "Previously summarized: $summary_count messages"
    echo "Has summary: $has_summary"
    echo "Estimated tokens: ~$total_tokens"
    echo "Token limit: $MAX_CONTEXT_TOKENS"
}

# ============================================================================
# Summarization
# ============================================================================

# Generate a summary of messages using the LLM
generate_summary() {
    local messages="$1"
    
    # Create a summarization prompt
    local summary_request
    summary_request=$(jq -n \
        --argjson msgs "$messages" \
        '[{
            role: "user",
            content: "Please provide a concise summary of the following conversation. Focus on key topics discussed, important information shared, any decisions or conclusions reached, and relevant context for continuing the conversation. Keep it under 200 words.\n\nConversation:\n"
        }] + $msgs + [{
            role: "user", 
            content: "\n\nNow provide the summary:"
        }]')
    
    # Call LLM to generate summary
    local summary
    summary=$(llm_chat "$summary_request")
    
    echo "$summary"
}

# Check if summarization is needed and perform it
check_and_summarize() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    # Get current messages for LLM (includes any existing summary)
    local messages
    messages=$(get_messages_for_llm "$session_id")
    
    local current_tokens
    current_tokens=$(estimate_messages_tokens "$messages")
    
    log_debug "Session $session_id: ~$current_tokens tokens (limit: $MAX_CONTEXT_TOKENS)"
    
    if [[ $current_tokens -lt $MAX_CONTEXT_TOKENS ]]; then
        # No summarization needed
        return 0
    fi
    
    log_info "Session $session_id exceeds token limit, summarizing..."
    
    # Get raw messages (we'll summarize older ones)
    local raw_messages
    raw_messages=$(get_raw_messages "$session_id")
    
    local message_count
    message_count=$(echo "$raw_messages" | jq 'length')
    
    if [[ $message_count -lt 4 ]]; then
        # Not enough messages to summarize
        log_info "Not enough messages to summarize ($message_count)"
        return 0
    fi
    
    # Calculate how many messages to keep (recent ones)
    # We want to keep roughly KEEP_RECENT_TOKENS worth of recent messages
    local keep_count=2  # Always keep at least 2 recent messages
    local running_tokens=0
    local i
    
    for (( i=message_count-1; i>=0; i-- )); do
        local msg_content
        msg_content=$(echo "$raw_messages" | jq -r ".[$i].content")
        local msg_tokens
        msg_tokens=$(estimate_tokens "$msg_content")
        
        if [[ $((running_tokens + msg_tokens)) -gt $KEEP_RECENT_TOKENS ]]; then
            break
        fi
        
        running_tokens=$((running_tokens + msg_tokens))
        keep_count=$((message_count - i))
    done
    
    # Ensure we have something to summarize
    local summarize_count=$((message_count - keep_count))
    if [[ $summarize_count -lt 2 ]]; then
        log_info "Not enough messages to summarize (would only summarize $summarize_count)"
        return 0
    fi
    
    log_info "Summarizing $summarize_count messages, keeping $keep_count recent"
    
    # Get messages to summarize (including any existing summary context)
    local old_summary
    old_summary=$(jq -r '.summary // empty' "$session_file")
    
    local messages_to_summarize
    if [[ -n "$old_summary" ]]; then
        # Include old summary in what we're summarizing
        messages_to_summarize=$(echo "$raw_messages" | jq --arg summary "$old_summary" \
            '[{role: "user", content: ("Previous summary: " + $summary)}] + .[:'"$summarize_count"']')
    else
        messages_to_summarize=$(echo "$raw_messages" | jq '.[:'"$summarize_count"']')
    fi
    
    # Generate new summary
    local new_summary
    new_summary=$(generate_summary "$messages_to_summarize")
    
    if [[ -z "$new_summary" ]] || [[ "$new_summary" == "Error:"* ]]; then
        log_error "Failed to generate summary: $new_summary"
        return 1
    fi
    
    # Get previous summary message count
    local prev_summary_count
    prev_summary_count=$(jq '.summary_message_count // 0' "$session_file")
    
    # Update session with new summary and trimmed messages
    local new_summary_count=$((prev_summary_count + summarize_count))
    local kept_messages
    kept_messages=$(echo "$raw_messages" | jq '.[-'"$keep_count"':]')
    
    jq -n \
        --arg summary "$new_summary" \
        --argjson count "$new_summary_count" \
        --argjson messages "$kept_messages" \
        '{
            summary: $summary,
            summary_message_count: $count,
            messages: $messages
        }' > "${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
    
    log_info "Session summarized. New context: ~$(estimate_messages_tokens "$(get_messages_for_llm "$session_id")") tokens"
    
    return 0
}

# ============================================================================
# Session Commands
# ============================================================================

# Clear session (remove all messages and summary)
clear_session() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    echo '{"messages":[]}' | jq '.' > "$session_file"
    log_info "Cleared session: $session_id"
}

# Force summarize current session
force_summarize() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    local raw_messages
    raw_messages=$(get_raw_messages "$session_id")
    
    local message_count
    message_count=$(echo "$raw_messages" | jq 'length')
    
    if [[ $message_count -lt 2 ]]; then
        echo "Not enough messages to summarize."
        return 1
    fi
    
    # Get existing summary
    local old_summary
    old_summary=$(jq -r '.summary // empty' "$session_file")
    
    local messages_to_summarize
    if [[ -n "$old_summary" ]]; then
        messages_to_summarize=$(echo "$raw_messages" | jq --arg summary "$old_summary" \
            '[{role: "user", content: ("Previous summary: " + $summary)}] + .')
    else
        messages_to_summarize="$raw_messages"
    fi
    
    # Generate summary of everything
    local new_summary
    new_summary=$(generate_summary "$messages_to_summarize")
    
    if [[ -z "$new_summary" ]] || [[ "$new_summary" == "Error:"* ]]; then
        echo "Failed to generate summary: $new_summary"
        return 1
    fi
    
    # Get previous summary message count
    local prev_summary_count
    prev_summary_count=$(jq '.summary_message_count // 0' "$session_file")
    
    local new_summary_count=$((prev_summary_count + message_count))
    
    # Save with summary and empty messages
    jq -n \
        --arg summary "$new_summary" \
        --argjson count "$new_summary_count" \
        '{
            summary: $summary,
            summary_message_count: $count,
            messages: []
        }' > "${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
    
    echo "Session summarized. $message_count messages condensed."
    echo ""
    echo "Summary:"
    echo "$new_summary"
}
