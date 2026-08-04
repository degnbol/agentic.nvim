---
name: provider-system
description:
  agentic.nvim provider/ACP plumbing — how this plugin handles ACP
  messages. Event pipeline (Transport → ACPClient → SessionManager →
  MessageWriter), session update routing, tool call lifecycle (two-phase
  tool_call / tool_call_update flow and the MessageWriter tracker),
  execute-tool rendering, adapter override points
  (`__handle_tool_call`, `__build_tool_call_update`,
  `__handle_request_permission`), and known ACP limitations as they
  affect this plugin. Use when editing `lua/agentic/acp/` (adapters,
  transport, client, session_manager) or debugging provider-specific
  bridge quirks (claude-agent-acp, opencode, gemini, codex). Distinct
  from the global `acp` skill which covers the ACP protocol spec
  itself.
---

# Provider System

## ACP Providers

The plugin spawns external CLI tools as subprocesses and talks ACP over stdio.
The full list of supported providers and their CLI requirements lives in
`Config.acp_providers` (`lua/agentic/config_default.lua`) — `Config.provider`
selects one of those keys. Per-provider quirks (message shape, missing fields,
non-standard `kind` values, etc.) are absorbed by an adapter in
`lua/agentic/acp/adapters/`. End-user install instructions are in the README.

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

### rawInput on tool_call vs update (claude-agent-acp)

Subagent (Task) calls carry `rawInput` on the initial `tool_call`; top-level
calls carry it on the refining `tool_call_update`. The claude adapter enriches
both build paths (`__apply_raw_input`) — else subagent edits render without a
diff.

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
instead of inline in the header. This lets the markdown treesitter parser inject
shell syntax highlighting automatically via its built-in injection queries. The
fence label comes from `shell_lang()` — the basename of `$SHELL` (e.g. `zsh`),
matching the shell the provider runs commands in (the same value sent in
`environment_info`), with `bash` as the fallback when `$SHELL` is unset. The
label is cosmetic: the zsh treesitter parser is aliased to `bash` via
`vim.treesitter.language.register("zsh", "bash")`, so highlighting is identical
regardless and the literal word is only visible at conceallevel=0.

Commands are formatted for readability using an external formatter (`shfmt` by
default, configurable via `tool_call_display.execute_formatter`). If the
formatter is not installed or errors, a built-in fallback splits long single-line
commands at top-level shell operators (&&, ||, ;, |).

### Description and output separation (claude-agent-acp)

The bridge sends a Bash call's `input.description` as the **initial tool_call
content**, and wraps the command output in a ` ```console ` fence on completion
(`tools.js` `toolInfoFromToolUse` / `toolUpdateFromToolResult` — the fence is a
template literal `` `\`\`\`console\n${output}\n\`\`\`` ``, so it does not show up
in a literal-backtick grep). Two consequences the adapter fixes
(`lift_execute_description` in `claude_agent_acp_adapter.lua`):

1. **Description is lifted to a title.** Without intervention the description
   seeds the body and accumulates ahead of the output behind a `---` divider
   (see body-accumulation in `update_tool_call_block`). The adapter moves it to
   `ToolCallBase.description`, which the renderer prints as a Comment-highlighted
   line directly under `### Execute`, above the command fence (see `shell_lang()`).
2. **The bridge's console fence is stripped.** `ClaudeShared.strip_console_fence`
   removes the ` ```console … ``` ` wrapper at the source. Without it `safe_fence`
   widens the outer fence to four backticks around the bridge's inner three,
   double-wrapping the output. `prepare_block_lines` also unwraps an
   already-fenced execute body as a final guard (idempotent), so single-wrapping
   is a property of the renderer — it survives a stale adapter instance after a
   hot-reload, or another provider that pre-fences.

The fence/non-fence distinction also separates the two payloads: claude Bash
output is always fenced, so unfenced execute content is the description echo and
is dropped from the body (the description is read from `rawInput.description`).

**Requirements for injection to work:**

- `vim.treesitter.start(chat_bufnr, "agentic")` must be called on the chat
  buffer (done in `ChatWidget:_create_buf_nrs`; `agentic` is a markdown-parser
  clone whose `injections.scm` inherits markdown, so bash/zsh injection still
  fires — see the folding note in the project CLAUDE.md). Falls back to
  `markdown` if the `agentic` language could not be registered.
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
              ```zsh                       (code fence, label from $SHELL — treesitter injection)
              ls -la /tmp
              ```
```

Multi-line commands (containing `\n`) are split into separate lines within the
fence rather than escaped to literal `\n`.

## Permission flow and client-side auto-approval

See the `permissions` project skill for the permission flow ASCII
diagram, the four auto-approval mechanisms, response keys table, and
the six `/trust` safety properties.

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

### No permission rule management via ACP

The Claude TUI has `/permissions` for viewing and editing persistent permission
rules (allow/deny patterns for tools). ACP has no equivalent — no command, no
schema, no API for querying, creating, or deleting permission rules
programmatically. The protocol defines only the per-tool-call approval flow
(`request_permission` with `allow_once`/`allow_always`/`reject_once`/
`reject_always` options).

When a user selects `allow_always` or `reject_always`, the provider may store
that rule internally, but the ACP client cannot inspect or manage those rules.
The protocol spec says only: "Clients MAY automatically allow or reject
permission requests according to user settings" — delegating the mechanism
entirely to the client.

This is why agentic.nvim implements three independent client-side layers (see
"Client-side auto-approval" above): read-only tool approval, compound Bash
command matching against `settings.json`, and the per-session allow/reject
always cache. For persistent rule management, users edit `~/.claude/settings.json`
directly (or `.claude/settings.json` for project-local rules).

### Buffer/disk divergence in diff matching

`diff_split_view.lua` and `tool_call_diff.lua` match `rawInput.old_string`
against file content to locate edit positions. If that fails, they fall
back to reverse matching (locate `new_string` and invert the diff).

Earlier docs attributed the reverse-match fallback to providers writing
edits to disk before sending `request_permission`. This is not what
happens — verified 2026-04-17 by inspecting disk contents while an Edit
permission prompt was pending. Do not plan new features around a pre-apply
race.

The legitimate divergence `read_from_buffer_or_disk` and the reverse-match
fallback actually guard against is buffer/disk skew: the buffer returns
content when loaded, but the provider operates on disk. Unsaved user edits
or autoread lag make both sides diverge. Both diff modules fall back to
`FileSystem.read_from_disk()` (bypasses loaded buffers) when buffer-based
matching fails. New diff code must include this disk fallback.

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

### `thought_level` (effort) ConfigOption — claude-agent-acp

As of `claude-agent-acp` 0.39.0 the bridge emits a `thought_level` ConfigOption
(`id = "effort"`), **conditional on the current model supporting effort**.
It is runtime-mutable via the ACP `session/set_config_option` method and rebuilt
on model switch — mirroring the TUI's `/effort`. Versions through 0.29.0 emitted
only `mode` and `model`; the old `maxThinkingTokens` passthrough is obsolete.

The plugin's `AgentConfigOptions:set_options` already dispatches on
`category == "thought_level"` (`agent_config_options.lua:88-89`), so the option
is captured into `self.thought_level`. A `/effort`-equivalent selector is now
unblocked: it would read `self.thought_level.options` and send the chosen value
via `session/set_config_option`. Provider-specific — non-Claude bridges may not
emit it.

### Mode switch kind inconsistency (claude-agent-acp)

The provider sends different `kind` values for plan mode entry vs exit:

| Tool | `kind` on `tool_call` | `title` on `tool_call` | `title` on final `tool_call_update` |
| --- | --- | --- | --- |
| EnterPlanMode | `"other"` | `"EnterPlanMode"` | `"EnterPlanMode"` |
| ExitPlanMode | `"switch_mode"` | `"Ready to code?"` | `"Exited Plan Mode"` |

Adapters must check both `kind == "other"` and `kind == "switch_mode"` in any
branch that handles mode switches. The `title` field is unstable — use pattern
matching (e.g. `title:match("^Ready%s")`) rather than exact string comparison.

### Tool kind casing varies by provider

The ACP schema spells kinds in lowercase (`"read"`, `"search"`, `"execute"`,
…), and most providers follow that. opencode emits capitalised kinds
(`"Read"`, `"Search"`) — which still render correctly because
`tool_call_renderer.display_kind` normalises case for the chat heading,
but a case-sensitive lookup table (e.g. `READ_ONLY_KINDS["Read"]`) silently
misses. Any kind-based dispatch must lowercase before lookup, or compose a
table that includes both casings. The chat heading is not a reliable signal
that the right `kind` arrived — `display_kind` hides the difference.

### Subagent content routed to a second buffer (parentToolUseId)

Forwarded subagent (Task) notifications carry `_meta.claudeCode.parentToolUseId`
(present ⟺ subagent content). `SessionManager` routes tagged message/thought
chunks to a dedicated `subagent_writer` (bound to `buf_nrs.subagent`) and records
tool-call ownership on the initial `tool_call` via `_writer_for`; the Task spawn
block itself stays in the main chat. The subagents split auto-opens on first
subagent activity of a turn. claude-agent-acp only — untagged providers never
populate the second buffer. See `notes/feature-subagent-separation.md`.

### Permission optionId is opaque

`request.options[].optionId` is a provider-assigned opaque string (e.g.
`"reject-once"`), NOT the same as `option.kind` (e.g. `"reject_once"`). To
determine the kind of a selected option, look up the option by `optionId` in the
original `request.options` array and read its `kind` field. Never compare
`optionId` directly against kind strings.

### Chat buffer is UI only — the model never reads it

The chat buffer is a client-side rendering artefact. On `session/load`
the provider replays its own conversation history (the SDK rebuilds
context from session JSON it owns, not from anything the client
stored), and on `session/prompt` the model only sees the prompt
content the client sends.

Consequence for feature design: anything that needs to reach the model
must travel through `session/prompt` — either embedded in the next
user prompt or via a synthetic prompt turn. Text rendered into the
chat buffer (status footers, decorations, trailing annotations on
tool-call blocks) is visible to the user only. It is not part of the
agent's conversation history and does not survive session resume into
the model's context.

There are three restore mechanisms that use this asymmetry differently:

- **Path A — true ACP `session/load`.** Requires
  `agentCapabilities.loadSession`. Sends the saved `sessionId` and the
  provider replays its own history via `session/update`
  notifications. `_history_to_send` is *not* set. Used by the picker
  when the agent supports it; both claude-agent-acp and opencode do.
- **Path B — `restore_from_history`** (`session_manager.lua`). Falls
  back when `loadSession` is unsupported or `session/load` errors.
  Creates a fresh `session/new`, replays the saved messages into the
  chat buffer locally, and stashes them on `self._history_to_send`.
  On the first `send_prompt`, `ChatHistory.prepend_restored_messages`
  (`ui/chat_history.lua`) injects them as text Content blocks
  (`"User: …"`, `"Assistant: …"`, `"Assistant (thinking): …"`, `"Tool
  call (…): …\nResult:\n…"`) ahead of the user's prompt. The provider
  sees one large user message — tool-call provenance is collapsed
  into prose, no native conversation state.
- **Path C — `respawn_after_usage_limit`** (`session_recovery.lua`).
  Triggered by `max_tokens` / usage-limit stalls on the
  claude-agent-acp subprocess. Kills the agent, saves
  `chat_history.messages` onto `_history_to_send`, and lets the next
  `session/new` reuse Path B's prefix-stitching to continue the
  conversation under a fresh subprocess.

This is the inverse of the "user_message_chunk replay" point below:
that section explains what the *client* receives on Path A (the
provider's history); this point explains what the *model* receives
(nothing the client wrote into its own buffer, only what the client
sent via session/prompt — including the Path B text prefix when that
fallback fires).

### user_message_chunk contains full prompt content

This applies to Path A only — Path B does not call `session/load`, so no
replay chunks arrive.

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

### Prompt loop stall — no client-side fix

The claude-agent-acp bridge can stall its prompt generator for one turn:
`agent_message_chunk` / `tool_call` / `tool_call_update` silently stop reaching
the client while `session/request_permission` keeps working, and the missing
content flushes on the next user prompt. The stall is upstream in the bridge's
prompt generator — the bytes never leave the bridge, so:

- **Nothing in `MessageWriter` or the dispatch layer can fix it** — the content
  never arrives. Client-layer tests in isolation cannot reproduce it.
- **Do not add client-side state resets** ("redraw", reset turn state) as a
  "fix" — they don't touch the bridge's stalled generator.
- Viable workarounds are upstream-level: respawn the subprocess before
  auto-continue (Path C `respawn_after_usage_limit`), re-prepending history.

### Silent upstream failure — opencode + litellm

Observed 2026-04-23 with opencode configured against a litellm backend using an
invalid API key. `session/prompt` returned a **successful** response shape with
no JSON-RPC error, no stderr, and no `agent_message_chunk` notifications:

```lua
response = {
  stopReason = "end_turn",
  usage = { inputTokens = 0, outputTokens = 0, totalTokens = 0 },
  _meta = {},
}
err = nil
```

Same response shape as the claude-agent-acp stall (see "Prompt loop stall"
above), but a different root cause: opencode swallows the upstream auth
rejection and reports normal completion.

**Zero-usage `end_turn` is not a reliable signal.** It can mean auth
rejection (the documented opencode + litellm case) but it also appears in
otherwise-working sessions — stalled generators per "Prompt loop stall",
cancelled turns reusing the prompt loop, models that simply return
nothing. There is no protocol-level way to distinguish these from a
client. A first-turn-only gate was tried and removed: `_is_first_message`
is also reset by `respawn_after_usage_limit`, so "first turn" doesn't
correspond to "first user prompt to the live agent", and the heuristic
produced false-positive Error blocks for normal empty responses.

**Surfacing rule** (implemented as `Recovery.surface_unexpected_response`
in `session_recovery.lua`, called from the `send_prompt` success branch
in `_handle_input_submit_inner`): render `response.stopReason` +
`response.usage` verbatim when `stopReason` is non-nil and not
`end_turn` or `cancelled`. That covers the provider-initiated reasons
(`max_tokens`, `max_turn_requests`, `refusal`) which arrive on the
success path and would otherwise be silently dropped. `end_turn`
(normal completion) and `cancelled` (user pressed Ctrl-C, see SKILL.md
§ "Stop reasons") are skipped. Auth-rejection cases like opencode +
litellm now manifest as an empty chat after the thinking indicator
clears; the user resolves them by checking provider credentials.

### Error classification keys on `err.data.errorKind`

`MessageWriter.format_error_lines` classifies JSON-RPC errors from the
bridge's structured `err.data.errorKind` (claude-agent-acp), authoritative
over the message-text heuristics (embedded JSON, usage-limit regex) which
remain as the display source and the fallback class for bridges lacking it.

### opencode Edit diff not at content[1]

Opencode follows the standard ACP diff layout (`content[]` array with
`{type="diff", path, oldText, newText}`), but on write/edit completion the
array contains the status-text entry **first** and the diff **second**:

```lua
content = {
    { type = "content", content = { type = "text", text = "Wrote file successfully." } },
    { type = "diff",    path = "...", oldText = "", newText = "..." },
}
```

The base class's `extract_content_body` only inspects `content[1]`, so
adapters that reuse the default need to scan the array themselves for the
diff entry. The opencode adapter does this in `__handle_tool_call_update`
and suppresses the status-text body when a diff is rendered, matching
claude-agent-acp's Edit block shape.

Codex/gemini/mistral adapters happen to work with `content[1]` because
those providers place the diff there. Don't assume any particular index.
