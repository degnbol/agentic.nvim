# Provider System

## ACP Providers (Agent Client Protocol)

This plugin spawn **external CLI tools** as subprocesses and communicate via the
Agent Client Protocol:

- **Requirements**: External CLI tools must be installed by the user, we don't
  install them for security reasons.
  - `claude-agent-acp` for Claude
  - `gemini` for Gemini
  - `codex-acp` for Codex
  - `opencode` for OpenCode
  - `cursor-agent-acp` for Cursor Agent
  - `auggie` for Augment Code
  - `vibe-acp` for Mistral Vibe

NOTE: Install instructs are in the README.md

## Provider adapters:

Each provider has a dedicated adapter in `lua/agentic/acp/adapters/`

These adapters implement provider-specific message formatting, tool call
handling, and protocol quirks.

## ACP provider configuration:

```lua
acp_providers = {
  ["claude-agent-acp"] = {
    name = "Claude Agent ACP",             -- Display name
    command = "claude-agent-acp",          -- CLI command to spawn
    env = {                                -- Environment variables
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
  ["gemini-acp"] = {
    name = "Gemini ACP",
    command = "gemini",
    args = { "--experimental-acp" },       -- CLI arguments
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
}
```

## Event pipeline (top to bottom)

```
Provider subprocess (external CLI)
  | stdio: newline-delimited JSON-RPC
  v
ACPTransport      -- parses JSON, calls callbacks.on_message()
  |
  v
ACPClient         -- routes by message type (notification vs response)
  |  adapter override point: __handle_tool_call,
  |  __handle_tool_call_update, __build_tool_call_update
  v
SessionManager    -- registered as subscriber per session_id
  |  routes by sessionUpdate type
  |  (see "Session update routing" below)
  v
MessageWriter     -- writes to chat buffer, tracks tool call state
PermissionManager -- queues permission prompts, manages keymaps
ChatHistory       -- accumulates messages for persistence
```

## Session update routing

`ACPClient` receives `session/update` notifications. The `sessionUpdate` field
determines routing:

| `sessionUpdate` value   | Routed to                                  |
| ----------------------- | ------------------------------------------ |
| `"tool_call"`           | adapter `__handle_tool_call` → subscriber  |
| `"tool_call_update"`    | adapter `__handle_tool_call_update` → sub  |
| `"agent_message_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"agent_thought_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"plan"`                | `TodoList.render()`                        |
| `"request_permission"`  | `PermissionManager` (queued, sequential)   |
| others                  | `subscriber.on_session_update()` (generic) |

## Tool call lifecycle

Tool calls go through **2 phases**. `MessageWriter` tracks each via
`tool_call_blocks[tool_call_id]`, persisting state across both phases.

**Phase 1 — `tool_call` (initial)**

```
Provider sends "tool_call"
  -> Adapter builds ToolCallBlock { tool_call_id, kind, argument, status, body?, diff? }
  -> subscriber.on_tool_call(block)
  -> MessageWriter:write_tool_call_block(block)
     1. Renders header + body/diff lines to buffer (footer is empty "")
     2. Writes status text into footer line via set_text + extmark highlight
     3. Creates sign_text extmarks (NS_DECORATIONS) for ╭─ │ ╰─ borders
     4. Creates range extmark (NS_TOOL_BLOCKS) as position anchor
     5. Stores block in tool_call_blocks[id]
```

**Phase 2 — `tool_call_update` (one or more)**

```
Provider sends "tool_call_update"
  -> Adapter builds ToolCallBase { tool_call_id, status, body?, diff? }
     (only CHANGED fields needed — MessageWriter merges)
  -> subscriber.on_tool_call_update(partial)
  -> MessageWriter:update_tool_call_block(partial)
     1. Looks up tracker = tool_call_blocks[id]
     2. Deep-merges via tbl_deep_extend("force", tracker, partial)
     3. Appends body (if both old and new exist and differ)
     4. Locates block position via range extmark
     5. If range extmark collapsed (start >= end): bails out, removes block
     6. Content unchanged (excludes footer from comparison): refresh status only
     7. Content changed: replace buffer lines, write status, re-render decorations
```

Status text is always real buffer content (written via `nvim_buf_set_text` to
avoid displacing sign extmarks), then highlighted with an extmark in the
`NS_STATUS` namespace. Extmarks work regardless of `vim.bo.syntax` state —
whether treesitter has disabled it (default) or a user re-enables it with
`vim.bo.syntax = 'ON'`. No deferred freezing, no cleanup passes. Blocks remain
tracked after terminal status.

## Key design rules for adapters

- **Updates are partial:** Only send what changed. MessageWriter merges onto the
  existing tracker via `tbl_deep_extend`. **Consumer-side implication:** fields
  like `argument` (file path) arrive in an early update but are absent from the
  `completed` status update. Code that inspects completed tool calls must read
  from the accumulated `tracker` (`message_writer.tool_call_blocks[id]`), not
  from the individual `tool_call_update` message.
- **Diffs are immutable after first render:** Once a diff is written to the
  buffer, content is frozen. Only status/decorations refresh on subsequent
  updates.
- **Body accumulates:** Multiple updates with different body content get
  concatenated with `---` dividers, not replaced.
- **Status is always real buffer text:** Footer line content is written via
  `nvim_buf_set_text` (not `set_lines`, which displaces extmarks), then
  highlighted with an extmark in the `NS_STATUS` namespace. No deferred
  freezing. Blocks stay tracked after terminal status.
- **Sign column for borders:** Block decorations (╭─ │ ╰─) use `sign_text`
  extmarks in the sign column rather than inline virtual text. This is more
  stable during buffer edits — signs survive line content replacement without
  needing delete/recreate cycles.

## Execute tool call rendering

Execute tool calls render their command inside a markdown fenced code block
(` ```bash `) instead of inline in the header. This lets the markdown treesitter
parser inject bash/zsh syntax highlighting automatically via its built-in
injection queries. The `bash` fence label is semantically correct (Claude Code
executes via bash), and the zsh treesitter parser handles it via
`vim.treesitter.language.register("zsh", "bash")`.

Commands are formatted for readability using an external formatter (`shfmt` by
default, configurable via `tool_call_display.execute_formatter`). If the
formatter is not installed or errors, a built-in fallback splits long single-line
commands at top-level shell operators (&&, ||, ;, |).

**Requirements for injection to work:**

- `vim.treesitter.start(chat_bufnr, "markdown")` must be called on the chat
  buffer (done in `ChatWidget:_create_buf_nrs`)
- The zsh treesitter parser must be installed (bash is aliased to zsh via
  `vim.treesitter.language.register("zsh", "bash")` in `init.lua` as fallback)
- The `_apply_block_highlights` Comment extmarks skip the code fence lines to
  avoid overriding treesitter highlights (extmark default priority 4096 >
  treesitter priority 100)

**Format comparison:**

```
All kinds:    "### Read"                   (heading — ### is @punctuation.special, kind is TOOL_KIND)
              "`/tmp/file.txt`"            (argument on next line, TOOL_ARGUMENT highlight)
Execute:      "### Execute"                (heading only, no argument line)
              ```bash                      (code fence — treesitter injection)
              ls -la /tmp
              ```
```

Multi-line commands (containing `\n`) are split into separate lines within the
fence rather than escaped to literal `\n`.

## Permission flow (interleaved with tool calls)

```
Provider sends "session/request_permission"
  -> PermissionManager:add_request(request, callback)
     -> _try_auto_approve() checks compound command against settings.json rules
        -> If approved: callback(allow_once) immediately, skip UI entirely
        -> If not: fall through to interactive prompt
     -> Queues request (sequential — one prompt at a time)
     -> Renders permission buttons in chat buffer
     -> Sets up buffer-local keymaps (1,2,3,4,0)
  -> User optionally presses diff_preview.open_in_tab keymap
     -> Opens diff preview in a new tabpage (opt-in)
  -> User presses permission key
     -> Sends result back to provider via callback
     -> Clears diff preview (if opened)
     -> Dequeues next permission if any
```

### Client-side auto-approval

`PermissionManager:_try_auto_approve()` runs two independent checks before
falling through to the interactive prompt. Either check can approve a request.

#### Read-only tools

Permission requests for ACP tool kinds `"read"` and `"search"` are always
approved without prompting. These cover Read, Grep, and Glob — tools that
cannot mutate the filesystem, regardless of target path. This bypasses the
provider's directory sandbox restriction, which otherwise prompts for paths
outside `additionalDirectories` even for read-only operations.

Controlled by `Config.auto_approve_read_only_tools` (default `true`).

#### Compound Bash commands

The ACP provider (e.g. claude-agent-acp) has its own permission rules, but its
pattern matching is limited: compound commands like `grep foo | head -20` prompt
even when both `Bash(grep *)` and `Bash(head *)` are in the user's allow list.
The provider matches the full command string against each pattern, not individual
segments.

`PermissionRules` (`lua/agentic/utils/permission_rules.lua`) adds a client-side
layer that fills this gap. When a Bash permission request arrives:

1. **Split** the command on top-level shell operators (`|`, `||`, `&&`, `;`),
   respecting quote boundaries
2. **Reject** unsafe constructs outright (subshells `$(...)`, backticks, process
   substitution `<(...)` / `>(...)`)
3. **Strip** harmless wrappers before matching: `stdbuf -oL` prefixes (added by
   hooks), `/dev/null` redirects (`2>/dev/null`, `&>/dev/null`, `2>&1`)
4. **Check** each segment against compiled patterns from `~/.claude/settings.json`
   and `.claude/settings.json` (project-local)
5. **Auto-approve** only if every segment matches an allow pattern AND no segment
   matches a deny/ask pattern

Patterns are the same `Bash(...)` glob syntax from Claude Code's settings.json.
`*` matches anything except shell operators. Deny/ask patterns always take
precedence over allow patterns (same as upstream). Compiled patterns are cached
with mtime-based invalidation (re-reads settings.json when it changes on disk).

Controlled by `Config.auto_approve_compound_commands` (default `true`).

### Permission response keys

| Key | Action | ACP outcome |
| --- | ------ | ----------- |
| `1` | Allow once | `selected` with `allow_once` option |
| `2` | Allow always | `selected` with `allow_always` option |
| `3` | Reject once (show next) | `selected` with `reject_once` option |
| `4` | Reject all | `reject_once` for current, `cancelled` for remaining |
| `5` | Reject always | `selected` with `reject_always` option |
| `<C-c>` | Hard abort | `cancelled` for all + `session/cancel` |

Key numbers match escalating severity: reject-all (4, local) comes before
reject-always (5, permanent rule). Numbers adapt if a provider sends fewer options.

**`4` vs `<C-c>`:** Both stop permission processing, but `4` sends `reject_once`
for the current tool call so the provider sees an active rejection and can adapt
(explain why, suggest alternatives). `<C-c>` kills the turn immediately via
`session/cancel` — the provider gets no chance to react. Use `4` when you want
to reject and provide follow-up feedback in the next turn.

### Permission button positions

Button positions are tracked via an extmark in the `NS_PERMISSION_BUTTONS`
namespace, not stored row numbers. `remove_permission_buttons` queries the
extmark to find the current position, making it robust against buffer shifts
from concurrent tool call updates.

## Adapter override points

Each provider adapter can override these **protected** methods on `ACPClient`:

| Method                        | Default behavior                          |
| ----------------------------- | ----------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock from standard fields |
| `__build_tool_call_update`    | Builds ToolCallBase with status + body    |
| `__handle_tool_call_update`   | Calls build then notifies subscriber      |
| `__handle_request_permission` | Sends result back to provider             |

Override when the provider sends data in non-standard fields (e.g. `rawInput`,
`rawOutput`), needs synthetic events (Gemini synthesizes `tool_call` from
permission request), or skips events (Gemini doesn't send cancel updates on
rejection).

## Known ACP limitations

### Edit applied before permission request

Providers (at least `claude-agent-acp`) write file edits to disk **before**
sending `request_permission`. By the time the plugin reads the file to show the
diff preview, the file already contains the new content. Matching
`rawInput.old_string` against the file fails because the old text is no longer
present.

Both `diff_split_view.lua` and `tool_call_diff.lua` handle this via reverse
matching: when forward matching fails, try matching `new_lines` against the file.
If that succeeds, the edit is already applied and the diff is reconstructed by
reversing the match. Any new diff-related code must account for both orderings.

**Buffer/disk divergence:** `read_from_buffer_or_disk` returns buffer content
when the buffer is loaded, but the provider operates on the disk version. When
the buffer has unsaved user edits or hasn't reloaded after a provider edit, both
forward and reverse matching against buffer content fail. Both diff modules fall
back to `FileSystem.read_from_disk()` (bypasses loaded buffers) when
buffer-based matching fails. New diff code must include this disk fallback.

### Slash commands intercepted locally

Some slash commands are handled entirely inside the provider process (TUI) and
**never emitted** via the ACP protocol — the prompt response returns
`{stopReason: "end_turn", usage: all zeros}` with no `agent_message_chunk`
notifications. Others behave differently through ACP than in the TUI.

These commands are intercepted in `SessionManager` before reaching the provider,
and injected as builtin completions in `SlashCommands.setCommands` (since
providers don't advertise them in `available_commands_update`):

- **`/context`**: Displays token usage from the most recent `usage_update`
  notification (which *is* sent via ACP). The chat header also shows a live
  context percentage from `usage_update`.
- **`/new`**: Manages session lifecycle locally (cancel, cleanup, fresh session).
- **`/clear`**: Aliased to `/new`. Through ACP, `/clear` doesn't actually reset
  provider context (unlike the TUI where it clears the conversation). Starting a
  fresh session is the only reliable way to clear context via ACP.
- **`/rename <name>`**: Updates `chat_history.title`, sets `session_name` in
  headers state (for external UI plugins via `AgenticHeadersChanged`), persists
  to the session JSON, and updates the buffer name. Resets on `/new`.

### Mode switch kind inconsistency (claude-agent-acp)

The provider sends different `kind` values for plan mode entry vs exit:

| Tool | `kind` on `tool_call` | `title` on `tool_call` | `title` on final `tool_call_update` |
| --- | --- | --- | --- |
| EnterPlanMode | `"other"` | `"EnterPlanMode"` | `"EnterPlanMode"` |
| ExitPlanMode | `"switch_mode"` | `"Ready to code?"` | `"Exited Plan Mode"` |

Adapters must check both `kind == "other"` and `kind == "switch_mode"` in any
branch that handles mode switches. The `title` field is unstable — use pattern
matching (e.g. `title:match("^Ready%s")`) rather than exact string comparison.

### Permission optionId is opaque

`request.options[].optionId` is a provider-assigned opaque string (e.g.
`"reject-once"`), NOT the same as `option.kind` (e.g. `"reject_once"`). To
determine the kind of a selected option, look up the option by `optionId` in the
original `request.options` array and read its `kind` field. Never compare
`optionId` directly against kind strings.

### user_message_chunk contains full prompt content

During `session/load` replay, the provider sends `user_message_chunk` events for
each content block in the original `session/prompt` request — not just user-typed
text. This includes system metadata (`<environment_info>`, `<command-name>`,
`<local-command-stdout>`, `<selected_code>` etc.) and instruction text ("IMPORTANT:
Focus and respect the line numbers…"). Only one chunk per turn contains actual
user prose.

`ACPClient` normally drops all `user_message_chunk` events (line 379) because the
plugin writes user messages locally on prompt submit. During `session/load`, it
forwards them instead (gated by `_loading_sessions[session_id]`). The
`SessionManager` handler filters out system metadata by checking if the trimmed
text starts with `<` or known instruction prefixes.

Any new code that processes replayed user messages must account for this: expect
multiple chunks per turn, most of which are system content.

### Non-JSON stdout/stderr forwarding

The transport layer forwards non-JSON stdout lines and non-ignored stderr lines
to subscribers via `on_stdout_text`. This is wired through `ACPClient` →
`SessionManager` → `MessageWriter`, gated by `is_generating` to suppress noise.
Currently no known ACP provider emits useful non-JSON stdout, but the
infrastructure exists for future use.
