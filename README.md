# Bashobot

Bashobot is a personal AI assistant built entirely in **pure bash** (compatible with bash 3.2+). Inspired by [OpenClaw](https://github.com/openclaw/openclaw), it uses only standard Unix utilities (`curl`, `jq`, `base64`, etc.) with no Node.js or other runtimes.

## Quick Start

```bash
# 1. First run creates config file
./bashobot.sh

# 2. Edit config with your API keys
vim ~/.bashobot/config.env

# 3. Start daemon
./bashobot.sh -daemon

# 4. Test with CLI
./bashobot.sh -cli
```

## Usage

```bash
# Start daemon (Telegram bot + pipe listener)
./bashobot.sh -daemon

# Start daemon (CLI only, no Telegram)
BASHOBOT_INTERFACE=none ./bashobot.sh -daemon

# Interactive CLI (connect to daemon via pipes)
./bashobot.sh -cli

# Send a single message
./bashobot.sh -t "What's 2+2?"

# Check status / stop
./bashobot.sh -status
./bashobot.sh -stop
```

## Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model [name]` | Show or switch model |
| `/tools [on|off]` | Show or toggle tool usage |
| `/allowcmd [cmd]` | Allow a shell command for tool execution |
| `/memory [cmd]` | Memory system (list, save, search, clear, on/off) |
| `/context` | Show session estimated context/token usage |
| `/clear` | Clear conversation (auto-saves to memory) |
| `/summarize` | Force summarize the conversation |
| `/exit` | Exit CLI (handled client-side, not sent to daemon) |

## Configuration

Edit `~/.bashobot/config.env`:

```bash
# LLM Provider (gemini, claude, openai)
BASHOBOT_LLM=gemini

# Interface (telegram, none)
BASHOBOT_INTERFACE=telegram

# Tools
BASHOBOT_TOOLS_ENABLED=true

# Keys
GEMINI_API_KEY=your_key
ANTHROPIC_API_KEY=your_key
OPENAI_API_KEY=your_key

# Telegram
TELEGRAM_BOT_TOKEN=your_token
TELEGRAM_ALLOWED_USERS=123456789  # Comma-separated user IDs (optional)

# Tool security (optional)
#BASHOBOT_ALLOWED_DIRS=/home/user,/tmp  # Restrict file access

# Heartbeat
#BASHOBOT_HEARTBEAT_ENABLED=true
#BASHOBOT_HEARTBEAT_INTERVAL=300

# Command whitelist
#BASHOBOT_CMD_WHITELIST_ENABLED=true
#BASHOBOT_CMD_WHITELIST_FILE=~/.bashobot/command_whitelist
```

## Architecture (Overview)

```
bashobot.sh                 # Main entry point
├── providers/              # Pluggable LLM backends
│   ├── gemini.sh           # Google Gemini (default)
│   ├── claude.sh           # Anthropic Claude
│   └── openai.sh           # OpenAI GPT
├── interfaces/             # Pluggable chat interfaces
│   ├── telegram.sh         # Telegram bot (long polling)
│   └── none.sh             # Dummy (CLI-only mode)
├── lib/                    # Core libraries
│   ├── core.sh             # Daemon loop + core runtime
│   ├── commands.sh         # Slash commands (/help, /model, etc.)
│   ├── tools.sh            # Tool implementations
│   ├── memory.sh           # Memory system
│   ├── session.sh          # Session management + summarization
│   ├── config.sh           # Config helpers
│   ├── json.sh             # JSON helpers
│   └── approval.sh         # Command whitelist approvals
└── ~/.bashobot/            # Runtime data (created at first run)
    ├── config.env          # User configuration (API keys)
    ├── sessions/           # Conversation history (JSON files)
    │   ├── <id>.json
    │   └── <id>.llm.json   # Full LLM request/response logs
    ├── pipes/              # Named pipes for IPC
    │   ├── input.pipe
    │   └── output.pipe
    ├── bashobot.pid        # Daemon PID file
    └── bashobot.log        # Log file
```

## Core Design Patterns

### Daemon + Named Pipes
- The daemon (`-daemon`) runs continuously.
- Inputs arrive via named pipe (`input.pipe`) and interfaces (e.g., Telegram polling).
- Clients (`-cli`, `-t`) send messages via the input pipe and read responses from the output pipe.
- Protocol: `SESSION_ID|SOURCE|MESSAGE` (input) and `SESSION_ID|BASE64_RESPONSE` (output).

### Pluggable Providers
Each provider implements:

```bash
llm_chat() {
    local messages="$1"  # JSON array: [{"role":"user","content":"..."},...]
    # Call API, return response text
    echo "$response_text"
}
```

### Pluggable Interfaces
Each interface implements:

```bash
interface_receive() {
    # Main loop - poll for messages, enqueue to daemon
}

interface_reply() {
    local session_id="$1"
    local message="$2"
    # Send message to the platform
}
```

## Tool Use

Bashobot supports tool calling for bash execution and file operations. Tools are enabled by default.

### Available Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands |
| `read_file` | Read file contents (with offset/limit support) |
| `write_file` | Write content to files (creates directories) |
| `list_files` | List directory contents |
| `memory_search` | Search past conversation memories |

### Tool Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_TOOLS_ENABLED` | `true` | Enable/disable all tools |
| `BASHOBOT_ALLOWED_DIRS` | (empty) | Comma-separated allowed directories (empty = all) |
| `BASHOBOT_MAX_OUTPUT` | `50000` | Max bytes of command output |

### Tool Security
- Set `BASHOBOT_TOOLS_ENABLED=false` to disable all tools.
- Use `BASHOBOT_ALLOWED_DIRS` to restrict file access.
- Output is truncated to prevent memory issues.

### Tool Internals (lib/tools.sh)

| Function | Purpose |
|----------|---------|
| `get_tools_definition()` | Get tool definitions (provider-agnostic) |
| `tool_execute()` | Dispatch and execute a tool by name |
| `tool_exec_shell()` | Execute bash commands |
| `tool_read_file()` | Read file contents |
| `tool_write_file()` | Write to files |
| `tool_list_dir()` | List directory contents |
| `tool_memory_search()` | Search conversation memories |
| `get_tools_gemini()` | Get tools in Gemini format |
| `get_tools_openai()` | Get tools in OpenAI format |
| `get_tools_claude()` | Get tools in Claude format |

## Memory System

Long-term memory through conversation summaries and keyword-based retrieval. Memories persist across sessions.

### How It Works
- Auto-save on `/clear`: conversations are saved to memory when cleared.
- Keyword extraction and topic extraction via LLM.
- Relevance search based on keywords.
- Relevant memories are injected at the start of new conversations.

### Memory Structure

```json
{
  "id": "mem_1234567890",
  "timestamp": "2024-01-15T10:30:00Z",
  "session_id": "original_session_id",
  "summary": "Conversation summary...",
  "keywords": ["keyword1", "keyword2"],
  "topics": ["topic1", "topic2"],
  "message_count": 15
}
```

### Memory Commands

| Command | Description |
|---------|-------------|
| `/memory` or `/memory list` | Show recent memories |
| `/memory save` | Save current session to memory |
| `/memory search <query>` | Search memories by keyword |
| `/memory clear` | Delete all memories |
| `/memory on|off` | Enable/disable memory system |

### Memory Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_MEMORY_ENABLED` | `true` | Enable/disable memory system |
| `MAX_MEMORIES_IN_CONTEXT` | `3` | Max memories to load into context |
| `MIN_MESSAGES_FOR_MEMORY` | `4` | Min messages before saving to memory |

## Session Management

Bashobot includes automatic context window management to prevent token limit issues and reduce API costs.

### How It Works
- Token estimation uses a character-based approximation (~4 chars per token).
- Auto-summarization triggers when context exceeds `MAX_CONTEXT_TOKENS`.
- Older messages are summarized; recent messages are preserved.
- Summary is prepended to future conversations.

### Session Structure

```json
{
  "summary": "Previous conversation summary...",
  "summary_message_count": 15,
  "messages": [
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi there!"}
  ]
}
```

### Session Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_CONTEXT_TOKENS` | 110000 | Trigger summarization at this token count |
| `KEEP_RECENT_TOKENS` | 2000 | Keep this many tokens of recent messages |
| `SUMMARY_MAX_TOKENS` | 500 | Target size for summaries |

### Session Internals (lib/session.sh)

| Function | Purpose |
|----------|---------|
| `estimate_tokens()` | Estimate token count from text |
| `get_messages_for_llm()` | Get messages with summary prepended |
| `check_and_summarize()` | Check limits and auto-summarize if needed |
| `clear_session()` | Clear all messages and summary |
| `force_summarize()` | Manually trigger summarization |
| `get_session_stats()` | Get context usage statistics |

## IPC Protocol

- Input pipe: `SESSION_ID|SOURCE|MESSAGE`
- Output pipe: `SESSION_ID|BASE64_ENCODED_RESPONSE`
- Base64 encoding handles multiline responses.

## Dependencies

- `bash` (3.2+)
- `curl` (HTTP requests)
- `jq` (JSON parsing)
- `base64` (response encoding)
- `pgrep`/`pstree` (process management)
- `mkfifo` (named pipes)

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

## License

MIT
