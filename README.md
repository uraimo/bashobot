<div align="center">
  <img src="https://github.com/uraimo/bashobot/blob/main/static/title.png?raw=true" width="600">
  <h2>A Personal AI Assistant built with Bash</h2>
  <p>
    <img src="https://img.shields.io/badge/bash-≥3.2-blue" alt="Bash">
    <img src="https://img.shields.io/badge/Shell-100%25-orange" alt="Bash">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  </p>
</div>


BashoBot is a personal AI assistant built entirely in **bash** (compatible with bash 3.2+). Inspired by [OpenClaw](https://github.com/openclaw/openclaw), it uses only standard Unix utilities (`curl`, `jq`, `base64`, etc.) with no Node.js or other runtimes, implemented with a modular architecture using named pipes. It can run almost anywhere.


<div align="center">
  <img src="https://github.com/uraimo/bashobot/blob/main/static/bashobot.gif?raw=true">
</div>

## Features

* Bash-only application, modular architecture based on named pipes
* Telegram or CLI interface
* All major providers supported
* All the basic OpenClaw features: tools, markdown memory, shared session, SOUL.md.
* Easy to launch inside a container if you want to be safe

## Quick Start

```bash
# 1. First run creates config file
./bashobot.sh

# 2. Edit config with your API keys or -login <provider>, optionally configure Telegram and enable/disable other features
vim ~/.bashobot/config.env

# 3. Start daemon (add & or use nohup to start in in background, stop it with ./bashbot.sh -stop)
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

# OAuth login for subscription providers
./bashobot.sh -login claude-sub

# OAuth logout for subscription providers
./bashobot.sh -logout claude-sub

# Check status / stop
./bashobot.sh -status
./bashobot.sh -stop
```

## Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model [name]` | Show or switch model |
| `/models` | List available models for current provider |
| `/tools [on,off]` | Show or toggle tool usage |
| `/login [provider]` | OAuth login (run `./bashobot.sh -login <provider>`) |
| `/allowcmd [cmd]` | Allow a shell command for tool execution |
| `/memory [cmd]` | Memory system (list, save, search, clear, on/off) |
| `/context` | Show session estimated context/token usage |
| `/new` | Start a new conversation (auto-saves to memory) |
| `/compact` | Force compact the conversation |
| `/exit` | Exit CLI (handled client-side, not sent to daemon) |

## Configuration

Edit `~/.bashobot/config.env`:

```bash
# LLM Provider (gemini, claude, openai, gemini-sub, claude-sub, openai-sub, antigravity-sub)
BASHOBOT_LLM=gemini

# Interface (telegram, none)
BASHOBOT_INTERFACE=telegram

# Tools
BASHOBOT_TOOLS_ENABLED=true

# Keys
GEMINI_API_KEY=your_key
ANTHROPIC_API_KEY=your_key
OPENAI_API_KEY=your_key

# Subscription OAuth (optional)
# Run: ./bashobot.sh -login <provider>
# Providers: claude-sub, openai-sub, gemini-sub, antigravity-sub
# Credentials are stored in ~/.bashobot/auth.json

# Telegram
TELEGRAM_BOT_TOKEN=your_token
TELEGRAM_ALLOWED_USERS=123456789  # Comma-separated user IDs (optional)

# Heartbeat                                        
#BASHOBOT_HEARTBEAT_ENABLED=true
#BASHOBOT_HEARTBEAT_INTERVAL=300

# Tool security (optional)
#BASHOBOT_ALLOWED_DIRS=/home/user,/tmp  # Restrict file access

# Command whitelist
#BASHOBOT_CMD_WHITELIST_ENABLED=true
#BASHOBOT_CMD_WHITELIST_FILE=~/.bashobot/command_whitelist
```

## Developer notes

A few additional information that could be useful if you plan to extend this manually or with an agent. Start from `core.sh` that contains the main loop of the daemon.

### Architecture (Overview)

```
bashobot.sh                 # Main entry point
├── providers/              # Pluggable LLM backends
│   ├── gemini.sh           # Google Gemini (API key)
│   ├── claude.sh           # Anthropic Claude (API key)
│   ├── openai.sh           # OpenAI GPT (API key)
│   ├── gemini-sub.sh       # Gemini subscription (OAuth)
│   ├── claude-sub.sh       # Claude subscription (OAuth)
│   ├── openai-sub.sh       # OpenAI Codex subscription (OAuth)
│   └── antigravity-sub.sh  # Antigravity subscription (OAuth)
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
    ├── workspace/          # Workspace prompt files
    │   ├── BOOTSTRAP.md     # Optional bootstrap prompt (copied from templates/)
    │   ├── BOOTSTRAP.done   # Bootstrap completion marker
    │   ├── SOUL.md          # System prompt snippet (copied from templates/)
    │   ├── IDENTITY.md      # System prompt snippet (copied from templates/)
    │   ├── USER.md          # System prompt snippet (copied from templates/)
    │   └── AGENTS.md        # System prompt snippet (copied from templates/)
    ├── sessions/           # Conversation history (JSON files)
    │   ├── <id>.json
    │   └── <id>.llm.json   # Full LLM request/response logs
    ├── pipes/              # Named pipes for IPC
    │   ├── input.pipe
    │   └── output.pipe
    ├── bashobot.pid        # Daemon PID file
    └── bashobot.log        # Log file
```

### Core Design Patterns

#### Daemon + Named Pipes
- The daemon (`-daemon`) runs continuously.
- Inputs arrive via named pipe (`input.pipe`) from the cli and other interfaces (e.g., Telegram polling).
- Clients (`-cli`, `-t`) send messages via the input pipe and read responses from the output pipe.
- Protocol: `SESSION_ID|SOURCE|MESSAGE` (input) and `SESSION_ID|BASE64_RESPONSE` (output).

#### Pluggable Providers
Each provider implements:

```bash
llm_chat() {
    local messages="$1"  # JSON array: [{"role":"user","content":"..."},...]
    # Call API, return response text
    echo "$response_text"
}
```

#### Pluggable Interfaces
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

### Tool Use

Bashobot supports tool calling for bash execution and file operations. Tools are enabled by default.

#### Available Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands |
| `read_file` | Read file contents (with offset/limit support) |
| `write_file` | Write content to files (creates directories) |
| `list_files` | List directory contents |
| `memory_search` | Search past conversation memories |

#### Tool Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_TOOLS_ENABLED` | `true` | Enable/disable all tools |
| `BASHOBOT_ALLOWED_DIRS` | (empty) | Comma-separated allowed directories (empty = all) |
| `BASHOBOT_MAX_OUTPUT` | `50000` | Max bytes of command output |

#### Tool Security
- Set `BASHOBOT_TOOLS_ENABLED=false` to disable all tools.
- Use `BASHOBOT_ALLOWED_DIRS` to restrict file access.
- Output is truncated to prevent memory issues.

#### Tool Internals (lib/tools.sh)

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

### Memory System

Long-term memory through markdown notes stored under `~/.bashobot/memory` and `~/.bashobot/MEMORY.md`.

#### How It Works
- Auto-save on `/new`: conversations are saved to memory when cleared.
- Keyword extraction and topic extraction via LLM.
- Relevance search based on keywords.
- Relevant memory notes are injected at the start of new conversations.

#### Memory Structure

- `~/.bashobot/MEMORY.md` — curated long‑term memory.
- `~/.bashobot/memory/YYYY-MM-DD.md` — daily notes and summaries.

#### Memory Commands

| Command | Description |
|---------|-------------|
| `/memory` or `/memory list` | Show recent memory files |
| `/memory save` | Save current session to memory notes |
| `/memory search <query>` | Search memory files for text |
| `/memory clear` | Delete all memory files |
| `/memory on,off` | Enable/disable memory system |

#### Memory Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASHOBOT_MEMORY_ENABLED` | `true` | Enable/disable memory system |
| `MAX_MEMORIES_IN_CONTEXT` | `3` | Max memories to load into context |
| `MIN_MESSAGES_FOR_MEMORY` | `4` | Min messages before saving to memory |

### Session Management

Bashobot includes automatic context window management to prevent token limit issues and reduce API costs.

#### How It Works
- Token estimation uses a character-based approximation (~4 chars per token).
- Auto-summarization triggers when context exceeds `MAX_CONTEXT_TOKENS`.
- Older messages are summarized; recent messages are preserved.
- Summary is prepended to future conversations.

#### Session Structure

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

#### Session Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_CONTEXT_TOKENS` | 110000 | Trigger summarization at this token count |
| `KEEP_RECENT_TOKENS` | 2000 | Keep this many tokens of recent messages |
| `SUMMARY_MAX_TOKENS` | 500 | Target size for summaries |

#### Session Internals (lib/session.sh)

| Function | Purpose |
|----------|---------|
| `estimate_tokens()` | Estimate token count from text |
| `get_messages_for_llm()` | Get messages with summary prepended |
| `check_and_summarize()` | Check limits and auto-summarize if needed |
| `clear_session()` | Clear all messages and summary |
| `force_summarize()` | Manually trigger summarization |
| `get_session_stats()` | Get context usage statistics |

### IPC Protocol

- Input pipe: `SESSION_ID|SOURCE|MESSAGE`
- Output pipe: `SESSION_ID|BASE64_ENCODED_RESPONSE`
- Base64 encoding handles multiline responses.

### Debugging

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

## Dependencies

- `bash` (3.2+)
- `curl` (HTTP requests)
- `jq` (JSON parsing)
- `base64` (response encoding)
- `pgrep`/`pstree` (process management)
- `mkfifo` (named pipes)


## FAQ

* *Is this a complete clone of OpenClaw?*: No and it doesn't plan to be, but it's small enough to show what the main components of a personal AI assistant are. The main objective of this project is to show that it's possible to build an assistant with the basic functionalities of OpenClaw  with just Bash and a bunch of utilities.

* *Should I put this on my MacMini?*: Probably not, you'd better use the fully featured OpenClaw, but a project like this could make sense if you want to turn something with a minimal Linux installation and limited capabilities (for example an old rooted NAS with a few Mbs of RAM) into a personal assistant. Customize the project and adapt it to your own needs.
 

## License

This project is distributed under the MIT License.

## Acknowledgements

The SOUL.md and some identity files from [OpenClaw](https://github.com/openclaw/openclaw), the obvious inspiration for this project.

