#!/bin/bash
#
# Bashobot Memory System
#
# Long-term memory through conversation summaries and keyword-based retrieval
#

# ============================================================================
# Configuration
# ============================================================================

# Enable/disable memory system (default: enabled)
BASHOBOT_MEMORY_ENABLED="${BASHOBOT_MEMORY_ENABLED:-true}"

# Memory storage directory
MEMORY_DIR="${CONFIG_DIR}/memories"

# Maximum memories to load into context
MAX_MEMORIES_IN_CONTEXT="${MAX_MEMORIES_IN_CONTEXT:-3}"

# Minimum messages before saving to memory
MIN_MESSAGES_FOR_MEMORY="${MIN_MESSAGES_FOR_MEMORY:-4}"

# ============================================================================
# Initialization
# ============================================================================

init_memory() {
    mkdir -p "$MEMORY_DIR"
}

# ============================================================================
# Memory Structure
# ============================================================================

# Each memory is a JSON file with:
# {
#   "id": "mem_1234567890",
#   "timestamp": "2024-01-15T10:30:00Z",
#   "session_id": "original_session_id",
#   "summary": "Conversation summary...",
#   "keywords": ["keyword1", "keyword2", ...],
#   "message_count": 15,
#   "topics": ["topic1", "topic2"]
# }

# ============================================================================
# Keyword Extraction
# ============================================================================

# Extract keywords from text using simple heuristics
# This is a lightweight alternative to embeddings
extract_keywords() {
    local text="$1"
    
    # Convert to lowercase, extract words, filter common words
    echo "$text" | \
        tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]' '\n' | \
        grep -v '^$' | \
        grep -vE '^(the|a|an|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|could|should|may|might|must|shall|can|need|dare|ought|used|to|of|in|for|on|with|at|by|from|as|into|through|during|before|after|above|below|between|under|again|further|then|once|here|there|when|where|why|how|all|each|every|both|few|more|most|other|some|such|no|nor|not|only|own|same|so|than|too|very|just|also|now|and|but|if|or|because|until|while|although|though|after|before|since|unless|about|against|among|around|behind|beside|besides|beyond|despite|down|during|except|inside|outside|over|past|per|plus|regarding|round|save|since|toward|towards|under|underneath|unlike|upon|versus|via|within|without|i|you|he|she|it|we|they|me|him|her|us|them|my|your|his|its|our|their|mine|yours|hers|ours|theirs|this|that|these|those|what|which|who|whom|whose|myself|yourself|himself|herself|itself|ourselves|themselves|something|anything|everything|nothing|someone|anyone|everyone|one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|new|old|good|bad|great|small|big|long|short|high|low|young|little|much|many|few|less|more|most|well|still|already|even|back|going|want|think|know|see|come|go|get|make|take|give|find|tell|ask|use|work|try|call|feel|become|leave|put|mean|keep|let|begin|seem|help|show|hear|play|run|move|live|believe|hold|bring|happen|write|provide|sit|stand|lose|pay|meet|include|continue|set|learn|change|lead|understand|watch|follow|stop|create|speak|read|allow|add|spend|grow|open|walk|win|offer|remember|love|consider|appear|buy|wait|serve|die|send|expect|build|stay|fall|cut|reach|kill|remain|suggest|raise|pass|sell|require|report|decide|pull)$' | \
        sort | uniq -c | sort -rn | \
        head -20 | \
        awk '{print $2}' | \
        tr '\n' ' ' | \
        sed 's/ $//'
}

# Extract topics/themes using LLM
extract_topics() {
    local summary="$1"
    
    local topic_request
    topic_request=$(jq -n --arg summary "$summary" '[{
        "role": "user",
        "content": ("Extract 3-5 main topics or themes from this conversation summary. Return only a comma-separated list of short topic phrases, nothing else.\n\nSummary:\n" + $summary)
    }]')
    
    local topics
    topics=$(llm_chat "$topic_request" 2>/dev/null || echo "general conversation")
    
    # Clean up the response
    echo "$topics" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -5 | tr '\n' ',' | sed 's/,$//'
}

# ============================================================================
# Memory Storage
# ============================================================================

# Generate a unique memory ID
generate_memory_id() {
    echo "mem_$(date +%s)_$$_$RANDOM"
}

# Save a conversation to memory
save_to_memory() {
    local session_id="$1"
    local summary="$2"
    local message_count="${3:-0}"
    
    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        return 0
    fi
    
    if [[ -z "$summary" ]]; then
        log_error "Cannot save empty summary to memory"
        return 1
    fi
    
    init_memory
    
    local memory_id
    memory_id=$(generate_memory_id)
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Extract keywords
    local keywords
    keywords=$(extract_keywords "$summary")
    
    # Extract topics (using LLM)
    local topics
    topics=$(extract_topics "$summary")
    
    # Create memory file
    local memory_file="$MEMORY_DIR/${memory_id}.json"
    
    jq -n \
        --arg id "$memory_id" \
        --arg timestamp "$timestamp" \
        --arg session_id "$session_id" \
        --arg summary "$summary" \
        --arg keywords "$keywords" \
        --arg topics "$topics" \
        --argjson message_count "$message_count" \
        '{
            id: $id,
            timestamp: $timestamp,
            session_id: $session_id,
            summary: $summary,
            keywords: ($keywords | split(" ")),
            topics: ($topics | split(",")),
            message_count: $message_count
        }' > "$memory_file"
    
    log_info "Saved memory: $memory_id ($message_count messages)"
    echo "$memory_id"
}

# Save current session to memory (extracts summary if needed)
save_session_to_memory() {
    local session_id="$1"
    local session_file
    session_file=$(session_file_path "$session_id")
    
    if [[ ! -f "$session_file" ]]; then
        return 1
    fi
    
    # Get message count
    local message_count
    message_count=$(jq '.messages | length' "$session_file")
    
    # Check minimum messages
    if [[ $message_count -lt $MIN_MESSAGES_FOR_MEMORY ]]; then
        log_info "Not enough messages to save to memory ($message_count < $MIN_MESSAGES_FOR_MEMORY)"
        return 0
    fi
    
    # Check if we already have a summary
    local existing_summary
    existing_summary=$(jq -r '.summary // empty' "$session_file")
    
    local summary
    if [[ -n "$existing_summary" ]]; then
        # Combine existing summary with current messages
        local current_messages
        current_messages=$(jq -c '.messages' "$session_file")
        local current_count
        current_count=$(echo "$current_messages" | jq 'length')
        
        if [[ $current_count -gt 0 ]]; then
            # Generate new combined summary
            local combined_request
            combined_request=$(jq -n \
                --arg prev_summary "$existing_summary" \
                --argjson msgs "$current_messages" \
                '[{
                    "role": "user",
                    "content": ("Create a concise summary combining this previous summary with the new conversation. Focus on key information, decisions, and context.\n\nPrevious summary:\n" + $prev_summary + "\n\nNew conversation:")
                }] + $msgs + [{
                    "role": "user",
                    "content": "\n\nCombined summary:"
                }]')
            summary=$(llm_chat "$combined_request")
        else
            summary="$existing_summary"
        fi
        
        # Get total message count including previously summarized
        local prev_count
        prev_count=$(jq '.summary_message_count // 0' "$session_file")
        message_count=$((prev_count + current_count))
    else
        # Generate summary from scratch
        local messages
        messages=$(jq -c '.messages' "$session_file")
        summary=$(generate_summary "$messages")
    fi
    
    if [[ -z "$summary" ]] || [[ "$summary" == "Error:"* ]]; then
        log_error "Failed to generate summary for memory: $summary"
        return 1
    fi
    
    save_to_memory "$session_id" "$summary" "$message_count"
}

# ============================================================================
# Memory Retrieval
# ============================================================================

# Calculate relevance score between query and memory
calculate_relevance() {
    local query="$1"
    local memory_file="$2"
    
    local query_keywords
    query_keywords=$(extract_keywords "$query")
    
    local memory_keywords
    memory_keywords=$(jq -r '.keywords | join(" ")' "$memory_file")
    
    local memory_topics
    memory_topics=$(jq -r '.topics | join(" ")' "$memory_file" | tr '[:upper:]' '[:lower:]')
    
    # Count matching keywords
    local score=0
    for keyword in $query_keywords; do
        if echo "$memory_keywords $memory_topics" | grep -qiw "$keyword"; then
            score=$((score + 1))
        fi
    done
    
    # Boost recent memories slightly
    local age_days
    age_days=$(( ($(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$(jq -r '.timestamp' "$memory_file")" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
    
    # Recency bonus (max 2 points for memories from today)
    if [[ $age_days -lt 1 ]]; then
        score=$((score + 2))
    elif [[ $age_days -lt 7 ]]; then
        score=$((score + 1))
    fi
    
    echo "$score"
}

# Search memories by relevance to a query
search_memories() {
    local query="$1"
    local max_results="${2:-$MAX_MEMORIES_IN_CONTEXT}"
    
    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo "[]"
        return
    fi
    
    init_memory
    
    # Score all memories
    local results="[]"
    
    for memory_file in "$MEMORY_DIR"/*.json; do
        [[ -f "$memory_file" ]] || continue
        
        local score
        score=$(calculate_relevance "$query" "$memory_file")
        
        if [[ $score -gt 0 ]]; then
            local memory_data
            memory_data=$(jq --argjson score "$score" '. + {relevance_score: $score}' "$memory_file")
            results=$(echo "$results" | jq --argjson mem "$memory_data" '. + [$mem]')
        fi
    done
    
    # Sort by relevance and return top results
    echo "$results" | jq --argjson max "$max_results" 'sort_by(-.relevance_score) | .[:$max]'
}

# Get all memories (for listing)
list_memories() {
    local limit="${1:-10}"
    
    init_memory
    
    local results="[]"
    
    for memory_file in "$MEMORY_DIR"/*.json; do
        [[ -f "$memory_file" ]] || continue
        
        local memory_data
        memory_data=$(jq '{id, timestamp, topics, message_count, summary: (.summary | .[0:100] + "...")}' "$memory_file")
        results=$(echo "$results" | jq --argjson mem "$memory_data" '. + [$mem]')
    done
    
    echo "$results" | jq --argjson limit "$limit" 'sort_by(.timestamp) | reverse | .[:$limit]'
}

# Get a specific memory by ID
get_memory() {
    local memory_id="$1"
    local memory_file="$MEMORY_DIR/${memory_id}.json"
    
    if [[ -f "$memory_file" ]]; then
        cat "$memory_file"
    else
        echo "null"
    fi
}

# Delete a memory
delete_memory() {
    local memory_id="$1"
    local memory_file="$MEMORY_DIR/${memory_id}.json"
    
    if [[ -f "$memory_file" ]]; then
        rm "$memory_file"
        log_info "Deleted memory: $memory_id"
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Memory Context Integration
# ============================================================================

# Load relevant memories into a message for context
get_memory_context() {
    local user_message="$1"
    
    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo ""
        return
    fi
    
    local relevant_memories
    relevant_memories=$(search_memories "$user_message")
    
    local memory_count
    memory_count=$(echo "$relevant_memories" | jq 'length')
    
    if [[ $memory_count -eq 0 ]]; then
        echo ""
        return
    fi
    
    # Format memories for context
    local context="Relevant context from previous conversations:\n\n"
    
    local i
    for ((i=0; i<memory_count; i++)); do
        local mem_date mem_summary mem_topics
        mem_date=$(echo "$relevant_memories" | jq -r ".[$i].timestamp" | cut -d'T' -f1)
        mem_summary=$(echo "$relevant_memories" | jq -r ".[$i].summary")
        mem_topics=$(echo "$relevant_memories" | jq -r ".[$i].topics | join(\", \")")
        
        context+="[$mem_date] Topics: $mem_topics\n$mem_summary\n\n"
    done
    
    echo -e "$context"
}

# Inject memory context into messages before LLM call
inject_memory_context() {
    local messages="$1"
    local user_message="$2"
    
    local memory_context
    memory_context=$(get_memory_context "$user_message")
    
    if [[ -z "$memory_context" ]]; then
        echo "$messages"
        return
    fi
    
    # Prepend memory context as a system-style message at the start
    echo "$messages" | jq --arg context "$memory_context" \
        '[{
            "role": "user",
            "content": $context
        }, {
            "role": "assistant", 
            "content": "I understand. I have context from our previous conversations that may be relevant."
        }] + .'
}

# ============================================================================
# Memory Commands (for commands.sh)
# ============================================================================

# Show memory status and list recent memories
cmd_memory_list() {
    local limit="${1:-5}"
    
    if [[ "$BASHOBOT_MEMORY_ENABLED" != "true" ]]; then
        echo "Memory system is disabled."
        echo "Enable with: BASHOBOT_MEMORY_ENABLED=true"
        return 0
    fi
    
    init_memory
    
    local count
    count=$(ls -1 "$MEMORY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    
    echo "Memory System Status"
    echo "===================="
    echo "Total memories: $count"
    echo "Max in context: $MAX_MEMORIES_IN_CONTEXT"
    echo ""
    
    if [[ $count -gt 0 ]]; then
        echo "Recent memories:"
        echo ""
        
        local memories
        memories=$(list_memories "$limit")
        
        echo "$memories" | jq -r '.[] | "[\(.timestamp | split("T")[0])] \(.topics | join(", "))\n  \(.summary)\n"'
    fi
}

# Save current session to memory manually
cmd_memory_save() {
    local session_id="$1"
    
    echo "Saving session to memory..."
    
    local memory_id
    memory_id=$(save_session_to_memory "$session_id")
    
    if [[ -n "$memory_id" ]]; then
        echo "Saved as: $memory_id"
    else
        echo "Nothing to save (not enough messages or save failed)"
    fi
}

# Search memories
cmd_memory_search() {
    local query="$1"
    
    if [[ -z "$query" ]]; then
        echo "Usage: /memory search <query>"
        return 0
    fi
    
    echo "Searching memories for: $query"
    echo ""
    
    local results
    results=$(search_memories "$query" 5)
    
    local count
    count=$(echo "$results" | jq 'length')
    
    if [[ $count -eq 0 ]]; then
        echo "No relevant memories found."
    else
        echo "$results" | jq -r '.[] | "[\(.timestamp | split("T")[0])] Score: \(.relevance_score)\n  Topics: \(.topics | join(", "))\n  \(.summary | .[0:150])...\n"'
    fi
}

# Clear all memories
cmd_memory_clear() {
    init_memory
    
    local count
    count=$(ls -1 "$MEMORY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    
    rm -f "$MEMORY_DIR"/*.json
    
    echo "Cleared $count memories."
}
