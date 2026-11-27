# Plan: pi as the only provider; remove the ACP layer
Status: draft
Priority: P3
Depends:

## Relevant files
- `lua/agentic/acp/` — all of it (8,296 lines)
- `lua/agentic/acp/adapters/claude_*.lua` — Claude-specific (3,302 lines)
- `lua/agentic/agent_client.lua`, `lua/agentic/pi/`, `pi/agentic.ts`
- `lua/agentic/session_manager.lua` — `_on_session_update`, the load replay (`_load_state`, `_replay_hold`, `_take_replay_update`, `_replay_entry`, `_dispatch_replay_tail`, `CONVERSATION_UPDATES`), `_new_session_after_failed_load`, `fork_at_cursor`
- `lua/agentic/session_recovery.lua` — login and usage-limit flows
- `lua/agentic/subagents.lua`, `ui/subagent_transcript.lua`, `ui/subagent_input.lua`
- `lua/agentic/permission_hook.lua`, `hooks/permission_hook.sh`, `hooks/subagent_hook.lua`
- `lua/agentic/utils/acp_kind.lua`, `lua/agentic/acp/canonical_tool_call.lua`
- `lua/agentic/config_default.lua` — `acp_providers`, `provider`
- Skills: `provider-system`, `session-lifecycle`, `subagents`, `permissions`
- `pi-claude-bridge` (`https://github.com/elidickinson/pi-claude-bridge`): README § Session history, § Provider options, § Hooks written for Claude Code; `src/index.ts` (the provider query options), `src/cc-child.ts` (`CLAUDE_MD_EXCLUDES`, `CC_CHILD_ENV`), `src/rate-limit.ts`
- pi 1.6.1 docs: `compaction.md`, `configuration.md` (context files, `SYSTEM.md`), `mcp.md`, `extensions.md` § `after_provider_response`, `rpc-extension-ui.md` § `setStatus`; source `src/core/system-prompt.ts` (`buildSystemPromptSections`)

## Background
Two client stacks run side by side: ACP (Claude
Code and the other ACP providers) and pi. Claude can run on pi through
`pi-claude-bridge`: it uses the Agent SDK with Claude Code's own login and
system prompt, keeps a Claude Code session file in step with pi's history,
and pi runs the tools. Its README states that use bills to the plan, like
Claude Code. With Claude on pi, every model goes through one client, and the
ACP layer, the adapters and the session load replay have no user.

The bridge uses Claude Code as the model client only. It starts Claude Code
with `tools: []`, `permissionMode: "bypassPermissions"`, user settings only,
and CLAUDE.md, AGENTS.md and `.claude/rules/**` excluded; pi supplies the
tools, the context files and the skills. Each capability that Claude Code
supplies today is therefore absent, or comes from somewhere else (step 8).

Claude runs on pi through the bridge (dotfiles `config/pi/install.sh`),
billed to the plan. Removal waits until it has been in daily use.

## Changes

### Remove
1. `config_default.lua`: `provider = "pi"`; remove `acp_providers` for all
   ACP providers. Their models are reached through pi's own providers.
2. `lua/agentic/acp/`: the client, the v2 codec, all adapters,
   `agent_config_options.lua`, `agent_modes.lua`, `agent_models.lua`,
   `acp_health.lua`, `usage_limit.lua`, `response_boundary.lua`. The
   transport moves to `lua/agentic/pi/`, as the UI's client of the harness
   interface (step 9).
3. `session_manager.lua`: the session load replay; a load is "render the chat
   JSON and start pi on the session file". The re-create from history stays
   only for a missing pi session file.
4. `session_recovery.lua`: the ACP login flow.
5. `permission_hook.lua`, `hooks/permission_hook.sh`,
   `hooks/subagent_hook.lua`, and `AGENTIC_SOCK` in the transport. Where
   the permission decision then runs is open question 2; today the pi
   extension sends every tool call to Neovim. The glob matcher layer
   (`PermissionRules.get_settings_patterns`): Claude's `settings.json`
   `Bash(...)` rules no longer apply. Its `deny` and `ask` rules that are
   still wanted move to `Config.permissions.structured` first.
6. Every provider reference that `rg -n -i 'opencode|gemini|codex|cursor|auggie|mistral'`
   finds in `lua/`, `tests/`, `doc/` and `.claude/skills/`. The `opencode`
   entry in `permissions.json` stays: it gates the `opencode` CLI. Dotfiles:
   `config/opencode/`, after its guards are ported to pi extensions.

### Rename
7. ACP-named shapes that stay as the plugin's own vocabulary get neutral
   names: `agentic.acp.*` types → `agentic.*`, `AcpKind` → `ToolKind`,
   `canonical_tool_call.lua` out of `acp/`. `PiClient` calls one handler
   per event (`on_message_chunk`, `on_usage`, …) in place of
   `on_session_update` with a `sessionUpdate` string.

### Capabilities that came from Claude Code
8. Each row gets one choice: a bridge option, a pi package, our own pi
   extension, or drop it. Each choice is harness work; how the UI shows
   its result is designed in step 9.

   | Capability | Under the bridge | Choices |
   |---|---|---|
   | Subagents (`Agent` tool, transcript views) | Absent | `pi-subagents`; own extension; drop |
   | Plan mode | Absent | `@narumitw/pi-plan-mode`; own extension; drop. A toggle changes pi's prompt, which costs a full history import |
   | Background commands with an output tail | Absent | `pi-background-tasks`; own extension; drop |
   | Todo list | Absent | A pi package that saves the list to history (`pi-todo-rail` adds it per request and breaks the prompt cache); own extension; drop |
   | Questions to the user | Absent | `FEAT-ask-tool.md` |
   | WebFetch, WebSearch | Absent | A pi package; own extension; drop |
   | Path-triggered rules (`.claude/rules/*.md`) | Not loaded: the bridge excludes them, and pi has no rules | Own extension that adds a rule when a tool call's path matches; move into skills; drop |
   | Project skills (`.claude/skills/`) | Not loaded: pi's `skills` setting has the user skills folder only | A second pi `skills` path |
   | User instructions and skills (dotfiles `config/pi/AGENTS.md`, `agents/skills/`) | Loaded, but written for Claude Code: skills named as slash commands (`/implement`), and `debug`, `lit`, `review` and `plan` spawn subagents | Rewrite for pi (`/skill:name`); the subagent steps follow the Subagents row. No Claude Code form is kept |
   | Claude Code's permission check (settings.json allow/deny/ask for every tool, the working-directory sandbox, path safety, the auto mode classifier for calls the rules leave undecided) | Off: `bypassPermissions`. The plugin's own checks still decide every call through the pi extension; an undecided call prompts | A pi package with a classifier; own classifier in the pi extension; prompt |
   | Claude Code hooks (`~/.claude/settings.json`) | Off: the user's hooks exit at once in a bridge turn | Per hook, `AUDIT-hooks-pi.md` |
   | MCP servers | Blocked (`strictMcpConfig` defaults to true) | pi's own MCP support; `strictMcpConfig: false` |
   | Auto-memory | Off | `autoMemoryEnabled: true`; a pi package; drop |
   | Plan usage limits | The bridge reports them as `anthropic-ratelimit-unified-*` headers on `after_provider_response` | Own extension that forwards them with `setStatus` to `PiClient.usage_limit`; drop |
   | Tool names and schemas | pi's tools, named `mcp__custom-tools__<name>` | pi's built-in tools; own extension tools with Claude Code's names and schemas (the prefix stays) |
   | System prompt | Claude Code's preset, then pi's prompt | Both; pi's only (`systemPromptPreset: false`); pi's base part replaced by `SYSTEM.md` |
   | Session data the chat does not show | Claude Code's session file keeps the system prompt (`prompt_snapshot`) and the context it adds to each turn (`environment`, `date`, `total_tokens_reminder`, `thinking_drop` attachments). pi's session file keeps pi's prompt sections and each thinking block's `thinkingSignature` (the encrypted full reasoning, which no client can decrypt; its size measures the hidden reasoning) | Harness (step 9) |
   | Compaction that reads earlier reasoning | pi compacts by default: `serializeConversation` (`src/core/compaction/utils.ts`) sends the history to the summarizing model as plain text with thinking left out, so the summary cannot use earlier reasoning. Claude Code sends the conversation itself plus a summary instruction, so the summarizing model reads the replayed reasoning | Own extension on `session_before_compact` that sends the conversation with its thinking blocks plus a summary instruction (example: `examples/extensions/custom-compaction.ts`); a pi package that does the same; accept pi's default. Not verified: that the bridge sends thinking blocks back on a request from an extension |
   | Thinking across an instruction change | Measured through the bridge (pi 1.6.1, Haiku 5.5, one `pi -p` process per prompt): with an unchanged pi prompt, the bridge forks its Claude Code session each turn and every earlier thinking block is sent and kept. A changed pi prompt (context file, skill, tool set) makes the bridge import the history into a new Claude Code session; the API drops every earlier thinking block (`prefix_binding_mismatch`) and the turn misses the cache. Claude Code today keeps the session's first prompt (`prompt_snapshot` in the session file), so edits wait for a new chat | Own extension that freezes pi's prompt per session (`before_agent_start`, the first prompt kept with `pi.appendEntry`); accept the import |

### Harness and UI
9. Two layers with one interface between them, designed separately:
   - **Harness**: pi, its packages and our own harness code (the permission
     decision, the prompt freeze, the usage-limit forwarding, the hooks
     from `AUDIT-hooks-pi.md`). Our harness code is TypeScript pi extensions, pi's own
     extension language, except where open question 2 decides otherwise.
     They are a pi package in this repo (`pi/package.json`), so the
     plugin needs no other repo: the plugin passes each with
     `--extension`, and any other pi client loads the package from pi's
     settings `packages`. Extensions that serve only the Neovim UI
     (`pi/agentic.ts`) stay out of the package manifest.
     It makes all session data available without a UI: messages, tool
     calls, thinking summaries with the signature size per block, the
     system prompt, the per-turn context from step 8, usage, plan limits.
   - **Interface**: pi's RPC mode (commands, events, extension UI
     requests), the data our extensions send over it (for example a
     `notify` with a fixed prefix), and pi's session files.
   - **UI**: the Neovim chat, in Lua. It shows only what the interface
     gives, and holds no harness decision. Which data it shows, and how,
     is a separate design per datum.

## Expected outcome
- Every chat runs on pi.
- `lua/agentic/acp/` is gone; no code branches on a provider.
- The harness gives every datum in step 9 to a client with no UI; the UI
  reads nothing but the harness interface.

## Non-goals
- Forking at a pi entry.

## Open questions
1. The choice in each row of step 8. `subagents.lua` (1,270 lines) and the
   transcript views are built on Claude's subagent updates, so every
   subagent choice except drop replaces them.
2. Where the permission decision runs (step 9). The other harness code is
   new and goes in TypeScript pi extensions. The permission decision is Lua in
   Neovim today: `permission_rules.lua`, `permission_structured.lua`,
   `shell_parse.lua`, `zsh_parse.lua`, `grant_safety.lua`,
   `git_files.lua` (about 10,100 lines, and 9,400 lines of tests). It
   parses each command with the zsh tree-sitter grammar through
   `vim.treesitter`, matches paths with `vim.glob` and `vim.lpeg`, and
   runs git with `vim.system`. Options:
   - Port to TypeScript in the pi extension: tree-sitter runs in Node
     through `web-tree-sitter` (a WASM build of the same zsh grammar, so
     the same node types) or the native `tree-sitter` binding. The cost is
     the port of the code and its tests. Not verified: a WASM build of the
     zsh grammar.
   - Keep the Lua and run it outside the editor: the extension calls a
     `nvim --headless -l` process. No port and no running editor, but the
     harness needs Neovim installed.
   - Keep it in the editor, as today: no port, but the harness needs a
     running editor.
