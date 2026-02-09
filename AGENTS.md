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
BASHOBOT_TOOLS_ENABLED=true      # Enable/disable tool use

GEMINI_API_KEY=your_key
ANTHROPIC_API_KEY=your_key
OPENAI_API_KEY=your_key

TELEGRAM_BOT_TOKEN=your_token
TELEGRAM_ALLOWED_USERS=123456789  # Comma-separated user IDs (optional)

# Tool security (optional)
#BASHOBOT_ALLOWED_DIRS=/home/user,/tmp  # Restrict file access
```

## Current Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model [name]` | Show or switch model (e.g., `/model gemini-2.5-pro`) |
| `/tools [on\|off]` | Show or toggle tool usage |
| `/memory [cmd]` | Memory system (list, save, search, clear, on/off) |
| `/context` | Show session context/token usage |
| `/clear` | Clear conversation (auto-saves to memory) |
| `/summarize` | Force summarize the conversation |
| `/exit` | Exit CLI (handled client-side, not sent to daemon) |

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

### Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_TOOLS_ENABLED` | `true` | Enable/disable all tools |
| `BASHOBOT_ALLOWED_DIRS` | (empty) | Comma-separated allowed directories (empty = all) |
| `BASHOBOT_MAX_OUTPUT` | `50000` | Max bytes of command output |

### Security

- Set `BASHOBOT_TOOLS_ENABLED=false` to disable all tools
- Use `BASHOBOT_ALLOWED_DIRS` to restrict file access to specific directories
- Output is truncated to prevent memory issues

### Key Functions (lib/tools.sh)

| Function | Purpose |
|----------|---------|
| `get_tools_definition()` | Get tool definitions (provider-agnostic) |
| `execute_tool()` | Dispatch and execute a tool by name |
| `tool_bash()` | Execute bash commands |
| `tool_read_file()` | Read file contents |
| `tool_write_file()` | Write to files |
| `tool_list_files()` | List directory contents |
| `tool_memory_search()` | Search conversation memories |
| `get_tools_gemini()` | Get tools in Gemini format |
| `get_tools_openai()` | Get tools in OpenAI format |
| `get_tools_claude()` | Get tools in Claude format |

## Memory System

Long-term memory through conversation summaries and keyword-based retrieval. Memories persist across sessions.

### How It Works

1. **Auto-save on /clear**: Conversations are automatically saved to memory when cleared
2. **Keyword Extraction**: Extracts keywords from summaries for search
3. **Topic Extraction**: Uses LLM to identify main topics
4. **Relevance Search**: Matches keywords between query and stored memories
5. **Context Injection**: Relevant memories are injected at the start of new conversations

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

### Commands

| Command | Description |
|---------|-------------|
| `/memory` or `/memory list` | Show recent memories |
| `/memory save` | Save current session to memory |
| `/memory search <query>` | Search memories by keyword |
| `/memory clear` | Delete all memories |
| `/memory on\|off` | Enable/disable memory system |

### Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_MEMORY_ENABLED` | `true` | Enable/disable memory system |
| `MAX_MEMORIES_IN_CONTEXT` | `3` | Max memories to load into context |
| `MIN_MESSAGES_FOR_MEMORY` | `4` | Min messages before saving to memory |

### Key Functions (lib/memory.sh)

| Function | Purpose |
|----------|---------|
| `save_to_memory()` | Save a summary to memory storage |
| `save_session_to_memory()` | Save current session to memory |
| `search_memories()` | Find relevant memories by query |
| `get_memory_context()` | Format memories for context injection |
| `inject_memory_context()` | Add memories to message array |
| `extract_keywords()` | Extract keywords from text |
| `extract_topics()` | Use LLM to identify topics |

## Session Management

Bashobot includes automatic context window management to prevent token limit issues and reduce API costs.

### How It Works

1. **Token Estimation**: Uses character-based approximation (~4 chars per token)
2. **Auto-Summarization**: When context exceeds `MAX_CONTEXT_TOKENS` (default: 8000):
   - Older messages are summarized using the LLM
   - Recent messages (last ~2000 tokens) are preserved
   - Summary is prepended to future conversations
3. **Session Structure**:
   ```json
   {
     "summary": "Previous conversation summary...",
     "summary_message_count": 15,
     "messages": [...]
   }
   ```

### Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_CONTEXT_TOKENS` | 110000 | Trigger summarization at this token count |
| `KEEP_RECENT_TOKENS` | 2000 | Keep this many tokens of recent messages |
| `SUMMARY_MAX_TOKENS` | 500 | Target size for summaries |

### Key Functions (lib/session.sh)

| Function | Purpose |
|----------|---------|
| `estimate_tokens()` | Estimate token count from text |
| `get_messages_for_llm()` | Get messages with summary prepended |
| `check_and_summarize()` | Check limits and auto-summarize if needed |
| `clear_session()` | Clear all messages and summary |
| `force_summarize()` | Manually trigger summarization |
| `get_session_stats()` | Get context usage statistics |

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

1. **More interfaces** - WhatsApp (via bridge), Discord, Slack
2. **Webhook mode** - Instead of Telegram polling, use webhooks
3. **Streaming** - SSE support for streaming responses
4. **More commands** - `/save`, `/load`, `/sessions`

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
