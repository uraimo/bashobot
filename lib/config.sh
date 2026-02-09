#!/bin/bash
#
# Bashobot Configuration Helpers
#

config_ensure_file() {
    if [[ -f "$CONFIG_DIR/config.env" ]]; then
        return 0
    fi

    cat > "$CONFIG_DIR/config.env" << 'EOF'
# Bashobot Configuration
# Uncomment and set your API keys

# LLM Provider (gemini, claude, openai)
#BASHOBOT_LLM=gemini

# Gemini
#GEMINI_API_KEY=your_key_here

# Claude
#ANTHROPIC_API_KEY=your_key_here

# OpenAI
#OPENAI_API_KEY=your_key_here

# Telegram
#TELEGRAM_BOT_TOKEN=your_token_here
#TELEGRAM_ALLOWED_USERS=user_id1,user_id2

# Interface (telegram, cli)
#BASHOBOT_INTERFACE=telegram

# Heartbeat
#BASHOBOT_HEARTBEAT_ENABLED=true
#BASHOBOT_HEARTBEAT_INTERVAL=300

# Command whitelist
#BASHOBOT_CMD_WHITELIST_ENABLED=true
# Command whitelist file
#BASHOBOT_CMD_WHITELIST_FILE=~/.bashobot/command_whitelist
EOF
    echo "Created config file: $CONFIG_DIR/config.env"
    echo "Please edit it with your API keys."
    exit 1
}

config_load() {
    config_ensure_file

    # Load config
    source "$CONFIG_DIR/config.env"

    # Set defaults AFTER loading config (so env vars take precedence)
    LLM_PROVIDER="${BASHOBOT_LLM:-gemini}"
    INTERFACE="${BASHOBOT_INTERFACE:-telegram}"
    HEARTBEAT_ENABLED="${BASHOBOT_HEARTBEAT_ENABLED:-true}"
    HEARTBEAT_INTERVAL="${BASHOBOT_HEARTBEAT_INTERVAL:-300}"

    # Load runtime overrides if present (e.g., last /model)
    if [[ -f "$CONFIG_DIR/runtime.env" ]]; then
        source "$CONFIG_DIR/runtime.env"
    fi
}

config_write_runtime() {
    local provider="$1"
    local model_name="$2"

    case "$provider" in
        gemini)
            {
                echo "LLM_PROVIDER=gemini"
                echo "GEMINI_MODEL=$model_name"
            } > "$CONFIG_DIR/runtime.env"
            ;;
        claude)
            {
                echo "LLM_PROVIDER=claude"
                echo "CLAUDE_MODEL=$model_name"
            } > "$CONFIG_DIR/runtime.env"
            ;;
        openai)
            {
                echo "LLM_PROVIDER=openai"
                echo "OPENAI_MODEL=$model_name"
            } > "$CONFIG_DIR/runtime.env"
            ;;
    esac
}
