# Bashobot

A personal AI assistant built entirely in bash. Inspired by [OpenClaw](https://github.com/openclaw/openclaw).

## Features

- **Multiple LLM Providers**: Gemini, Claude, OpenAI (pluggable architecture)
- **Named Pipe IPC**: Send messages from other scripts/terminals
- **Multi-channel**: Chat with your bot on Telegram or other channels
- **Session Persistence**: Conversations saved to JSON files

## Requirements

- `bash` 4.0+
- `curl`
- `jq`

## Quick Start

```bash
# 1. First run creates config file
./bashobot.sh

# 2. Edit config with your API keys
nano ~/.bashobot/config.env

# 3. Start daemon
./bashobot.sh -daemon

# 4. Test with CLI
./bashobot.sh -cli
```

## Usage

```bash
# Start the daemon (Telegram bot + pipe listener)
./bashobot.sh -daemon

# Interactive CLI (connect to the daemon via pipe with a simple cli)
./bashobot.sh -cli

# Send a single message to the running daemon
./bashobot.sh -t "What's 2+2?"

# Check daemon status
./bashobot.sh -status

# Stop daemon
./bashobot.sh -stop
```

## Configuration

Edit `~/.bashobot/config.env`:

```bash
# LLM Provider (gemini, claude, openai)
BASHOBOT_LLM=gemini

# Gemini API Key
GEMINI_API_KEY=<your_key_here>

# Telegram Bot Token (get from @BotFather)
TELEGRAM_BOT_TOKEN=<your_token_here>

# Optional: Restrict to specific Telegram users
TELEGRAM_ALLOWED_USERS=123456789,987654321
```

## Architecture

```
bashobot.sh              # Main entry point
├── providers/           # LLM providers (pluggable)
│   ├── gemini.sh
│   ├── claude.sh
│   └── openai.sh
├── interfaces/          # Chat interfaces (pluggable)
│   ├── telegram.sh
│   └── none.sh
└── ~/.bashobot/         # Runtime data
    ├── config.env       # Configuration
    ├── sessions/        # Conversation history (JSON)
    ├── pipes/           # Named pipes for IPC
    └── bashobot.log     # Logs
```

## Adding a New Provider

Create `providers/myprovider.sh`:

```bash
#!/bin/bash
# Validate config
if [[ -z "${MY_API_KEY:-}" ]]; then
    echo "Error: MY_API_KEY not set" >&2
    exit 1
fi

# Main function - must be named llm_chat
# Input: JSON array of messages [{"role":"user","content":"..."}]
# Output: Response text
llm_chat() {
    local messages="$1"
    # Call your API with curl
    # Return response text
    echo "Response from my provider"
}
```

Use it: `BASHOBOT_LLM=myprovider ./bashobot.sh -cli`

## Adding a New Interface

Create `interfaces/myinterface.sh`:

```bash
#!/bin/bash

# Called when daemon starts - run your polling/webhook loop
interface_start() {
    while true; do
        # Get messages from your platform
        # For each message:
        #   init_session "$session_id"
        #   response=$(process_message "$session_id" "$text" "myinterface")
        #   # Send response back
        sleep 1
    done
}

# Called to send a message
interface_send() {
    local session_id="$1"
    local message="$2"
    # Send message to your platform
}
```

Use it: `BASHOBOT_INTERFACE=myinterface ./bashobot.sh -daemon`

## Named Pipe Protocol

The daemon listens on `~/.bashobot/pipes/input.pipe` for messages in format:
```
SESSION_ID|SOURCE|MESSAGE
```

Responses are written to `~/.bashobot/pipes/output.pipe`:
```
SESSION_ID|RESPONSE
```

Example:
```bash
# Send a message
echo "my_session|pipe|Hello bot" > ~/.bashobot/pipes/input.pipe

# Read response
cat ~/.bashobot/pipes/output.pipe
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BASHOBOT_LLM` | LLM provider | `gemini` |
| `BASHOBOT_INTERFACE` | Chat interface | `telegram`, `none` |
| `BASHOBOT_CONFIG_DIR` | Config directory | `~/.bashobot` |
| `VERBOSE=1` | Enable verbose output | - |
| `GEMINI_MODEL` | Gemini model | `gemini-3.0-flash` |
| `CLAUDE_MODEL` | Claude model | `claude-sonnet-4-20250514` |
| `OPENAI_MODEL` | OpenAI model | `gpt-4o` |

## License

MIT
