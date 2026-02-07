# Bashobot - Agent Context

## Project Overview

Bashobot is a personal AI assistant built entirely in **pure bash** (compatible with bash 3.2+). It's inspired by [OpenClaw](https://github.com/openclaw/openclaw) but uses only standard Unix utilities (`curl`, `jq`, `base64`, etc.) with no Node.js or other runtimes.

## Architecture

```
bashobot.sh                 # Main entry point (~450 lines)
├── providers/              # Pluggable LLM backends
│   ├── gemini.sh           # Google Gemini (default)
│   ├── claude.sh           # Anthropic Claude
│   └── openai.sh           # OpenAI GPT
├── interfaces/             # Pluggable chat interfaces
│   ├── telegram.sh         # Telegram bot (long polling)
│   └── none.sh             # Dummy (CLI-only mode)
├── lib/
│   └── commands.sh         # Slash commands (/help, /model, etc.)
└── ~/.bashobot/            # Runtime data (created at first run)
    ├── config.env          # User configuration (API keys)
    ├── sessions/           # Conversation history (JSON files)
    ├── pipes/              # Named pipes for IPC
    │   ├── input.pipe
    │   └── output.pipe
    ├── bashobot.pid        # Daemon PID file
    └── bashobot.log        # Log file
```

## Core Design Patterns

### 1. Daemon + Named Pipes Architecture
- The daemon (`-daemon`) runs continuously, listening on:
  - Named pipe (`input.pipe`) for CLI/programmatic messages
  - Telegram API (long polling) for chat messages
- Clients (`-cli`, `-t`) send messages via the input pipe and read responses from the output pipe
- Protocol: `SESSION_ID|SOURCE|MESSAGE` (input), `SESSION_ID|BASE64_RESPONSE` (output)

### 2. Pluggable Providers
Each provider implements:
```bash
llm_chat() {
    local messages="$1"  # JSON array: [{"role":"user","content":"..."},...]
    # Call API, return response text
    echo "$response_text"
}
```

### 3. Pluggable Interfaces
Each interface implements:
```bash
interface_start() {
    # Main loop - poll for messages, call process_message(), send replies
}
interface_send() {
    local session_id="$1"
    local message="$2"
    # Send message to the platform
}
```

### 4. Slash Commands
Commands in `lib/commands.sh` are processed before LLM. Pattern:
```bash
cmd_mycommand() {
    local session_id="$1"
    shift
    local args="$*"
    echo "Response"
    return 0  # 0=handled, 1=pass to LLM
}
# Then add to case statement in process_command()
```

## Key Functions (bashobot.sh)

| Function | Purpose |
|----------|---------|
| `main()` | Entry point, parses CLI args |
| `daemon_loop()` | Main daemon loop, listens on pipes |
| `process_message()` | Routes messages to commands or LLM |
| `send_message()` | Client-side: sends to daemon via pipe |
| `init_session()` / `append_message()` / `get_messages()` | Session management |
| `load_provider()` / `load_interface()` | Dynamic loading |
| `stop_daemon()` | Kills daemon and all children |

## Usage

```bash
# Start daemon (with Telegram)
./bashobot.sh -daemon

# Start daemon (CLI only, no Telegram)
BASHOBOT_INTERFACE=none ./bashobot.sh -daemon

# Interactive CLI (requires daemon running)
./bashobot.sh -cli

# Send single message
./bashobot.sh -t "Hello"

# Check status / stop
./bashobot.sh -status
./bashobot.sh -stop
```

## Configuration (~/.bashobot/config.env)

```bash
BASHOBOT_LLM=gemini              # Provider: gemini, claude, openai
BASHOBOT_INTERFACE=telegram      # Interface: telegram, none

GEMINI_API_KEY=your_key
ANTHROPIC_API_KEY=your_key
OPENAI_API_KEY=your_key

TELEGRAM_BOT_TOKEN=your_token
TELEGRAM_ALLOWED_USERS=123456789  # Comma-separated user IDs (optional)
```

## Current Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model [name]` | Show or switch model (e.g., `/model gemini-2.5-pro`) |
| `/exit` | Exit CLI (handled client-side, not sent to daemon) |

## Technical Notes

### Bash 3.2 Compatibility
- No associative arrays (`declare -A`)
- No `|&` pipe syntax
- Use `[ ]` or `[[ ]]` carefully
- No `readarray`/`mapfile`

### Process Management
- Daemon saves PID to `~/.bashobot/bashobot.pid`
- Stop kills entire process tree using `pstree` or `pgrep -P`
- Trap on SIGTERM/SIGINT for cleanup

### IPC Protocol
- Input pipe: `SESSION_ID|SOURCE|MESSAGE`
- Output pipe: `SESSION_ID|BASE64_ENCODED_RESPONSE`
- Base64 encoding handles multiline responses

### Session Storage
JSON files in `~/.bashobot/sessions/`:
```json
{
  "messages": [
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi there!"}
  ]
}
```

## Dependencies

- `bash` (3.2+)
- `curl` (HTTP requests)
- `jq` (JSON parsing)
- `base64` (response encoding)
- `pgrep`/`pstree` (process management)
- `mkfifo` (named pipes)

## Future Improvements (Ideas)

1. **Tool use** - Add bash execution, file read/write capabilities
2. **Memory system** - Summarize old conversations, context window management
3. **More interfaces** - WhatsApp (via bridge), Discord, Slack
4. **Webhook mode** - Instead of Telegram polling, use webhooks
5. **Streaming** - SSE support for streaming responses
6. **More commands** - `/clear`, `/save`, `/load`, `/sessions`

## Debugging

```bash
# Verbose mode
VERBOSE=1 ./bashobot.sh -daemon

# Check logs
tail -f ~/.bashobot/bashobot.log

# Check running processes
ps aux | grep bashobot

# Manual pipe test
echo "test_session|pipe|/help" > ~/.bashobot/pipes/input.pipe
cat ~/.bashobot/pipes/output.pipe | cut -d'|' -f2 | base64 -d
```
