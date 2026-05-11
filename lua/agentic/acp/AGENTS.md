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

**Why this exists.** The plugin is the ACP client, strictly downstream of the
provider's own permission system — we can't override what the SDK silently
approves or denies, only decide how to handle what it escalates as `ask`. Each
layer below targets a specific provider/protocol gap that causes
otherwise-authorised work to be re-prompted; together they reduce prompt
fatigue without *adding* trust beyond what the user already wrote in
`settings.json`. The one exception is `/trust`, which grants new authorisation
and compensates by gating on git-recoverability (the user can undo any
auto-approved edit). Every layer is disablable via `Config.auto_approve_*`,
and state is per-session — nothing crosses `/new`.

`PermissionManager:_try_auto_approve()` runs four independent checks before
falling through to the interactive prompt. Any check can approve (or reject) a
request. The compound-command check (#2) is itself fed by two pattern sources:
the user's Claude settings.json and a built-in curated list of read-only Bash
commands (described inline below).

#### Read-only tools

Permission requests for ACP tool kinds `"read"` and `"search"` are always
approved without prompting. These cover Read, Grep, and Glob — tools that
cannot mutate the filesystem, regardless of target path. This bypasses the
provider's directory sandbox restriction, which otherwise prompts for paths
outside `additionalDirectories` even for read-only operations.

The kind check has a fallback: if `request.toolCall.kind` does not match
but the tracker entry created by the prior `tool_call` notification has a
read-only kind, auto-approve anyway. This handles opencode's pattern of
raising `external_directory` (kind="other") under the same `toolCallId`
as the underlying read tool — see acp skill `references/opencode.md`
§ "Permission request shape" finding 1.

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
   hooks), `/dev/null` redirects (`2>/dev/null`, `&>/dev/null`), and file
   descriptor duplications (`2>&1`, `>&N`, `N>&M`) — none of these write
   to user files
4. **Reject** segments containing any other output redirection (`>`, `>>`,
   `2>`, `&>` to a file). The redirect would write to a file regardless
   of how innocent the source command looks, so allowing `cat foo > evil`
   to slip through `Bash(cat *)` would silently write `evil`. In-place
   modification flags (e.g. `sed -i`) are caught by the deny list rather
   than by redirect detection.
5. **Check** each segment against compiled patterns from two sources, merged:
   - `~/.claude/settings.json` and `.claude/settings.json` (project-local) —
     Claude-specific, mtime-cached.
   - `Config.read_only_commands` / `Config.read_only_commands_deny` — a
     curated built-in list of safe read-only Bash commands (`ls`, `cat`,
     `head`, `find` minus `-exec`/`-delete`/`-ok`, etc.) that applies to
     every provider, not just Claude. Gated by
     `Config.auto_approve_read_only_commands` (default `true`).
6. **Auto-approve** only if every segment matches an allow pattern AND no segment
   matches a deny/ask pattern

Patterns are the same `Bash(...)` glob syntax from Claude Code's settings.json.
`*` matches anything except shell operators. Deny/ask patterns always take
precedence over allow patterns (same as upstream). The settings.json patterns
are cached with mtime-based invalidation; the Config-derived patterns are
recompiled only when the user replaces the list (table-reference identity).

Controlled by `Config.auto_approve_compound_commands` (default `true`) — the
master switch that gates the whole compound-command path. The built-in list
has its own opt-out (`auto_approve_read_only_commands`) so users with no
Claude settings.json still get a sensible baseline, and users who want only
their own settings.json patterns can disable the built-ins independently.

The command source has a fallback: if `request.toolCall.rawInput.command`
is nil and the tracker's kind is `"execute"`, the check reads the command
from `tracker.argument` instead. This handles opencode, which sends
`metadata: {}` on shell permission requests but populates `rawInput.command`
on the tool_call_update that fires just before — see acp skill
`references/opencode.md` § "Permission request shape" finding 3.

#### Allow/reject always cache

ACP providers don't reliably persist `allow_always`/`reject_always` decisions
(the protocol leaves persistence as provider-specific behaviour). The plugin
caches these decisions in `PermissionManager._always_cache` and auto-approves
or auto-rejects subsequent matching requests.

Cache keys are scoped by tool kind:
- **File-scoped** (edit, write, create, delete, move): `kind:file_path`
- **Other kinds**: `kind` alone

When a cached `allow` entry matches, the plugin sends `allow_once` back to the
provider (same as the other auto-approval checks). When a cached `reject` entry
matches, it sends `reject_once`.

The cache is per-session — cleared by `clear()` (called on `/new`, session
cancel, and tabpage close).

#### Trust scope (`/trust`)

The `/trust` slash command sets a per-session scope inside which file-scoped
tool kinds (edit, write, create, delete, move) auto-approve when the change is
safely recoverable. Three reserved literals plus any path/glob:

- `repo` — any git-tracked file in the current repo
- `here` — git-tracked files under the activation cwd
- `off` — clear the scope
- any other string — literal path or `vim.glob.to_lpeg` glob

Scope membership is **necessary but not sufficient** — the orchestrator
(`PermissionManager:_check_trust`) layers the following safety properties on
top before approving:

1. **Symlink resolution.** Both the original path AND its `vim.uv.fs_realpath`
   must lie inside the scope. A tracked symlink pointing outside (e.g.
   `~/.ssh/authorized_keys`) is rejected.
2. **Per-kind recoverability** (see `safe_for_kind` in
   `lua/agentic/utils/trust_safety.lua`):
   - `create` — file does not exist
   - `write` — new file, OR tracked + working tree clean
   - `delete` — tracked + clean
   - `edit` — new file, tracked + clean, **pure addition** (diff.old is a
     contiguous line subsequence of diff.new, so user content anchored by
     old_string is preserved verbatim inside new_string), edit range
     disjoint from unstaged hunks, OR every overlapping hunk is a verified
     Claude-owned range
   - `move` — source satisfies `edit`, destination satisfies `write`, both
     symlink endpoints in scope
3. **Verified Claude-owned range.** Ranges are recorded at edit time, not
   re-discovered at check time. At the initial `tool_call` notification
   (before the SDK applies the edit — see "Edits are not applied before
   permission"), `SessionManager:_record_pending_edit_range` reads the file
   and finds `diff.old` as a unique line subsequence. The start line is
   stashed in `PermissionManager._pending_edits`. When the matching
   `tool_call_update` arrives with `status: "completed"`,
   `finalize_edit_range` promotes it to `_edit_records` with
   `end_line = start_line + #diff.new - 1` and the recorded `new_lines`.
   At trust-check time, `TrustSafety.verify_edit_range` confirms the
   on-disk content at the recorded range still equals `new_lines`. Any
   divergence (user edit, or a later Claude edit that shifted those
   lines) drops the record and falls through.

   **Why range-based, not content-search:** Claude's Edit tool is
   string-based (no line numbers in the payload, see acp skill's Edit tool
   section), and the SDK's `FileEditOutput.structuredPatch` is **not
   forwarded** by the claude-agent-acp bridge — `rawOutput` is flattened to
   a plain success string. We synthesise ranges ourselves using the tool's
   uniqueness contract on `old_string`. Searching for `diff.new` at check
   time would be ambiguous when the new content coincides with other file
   text (e.g. short replacements like `}`, `end`, blank lines).
4. **TOCTOU revalidation.** Capture `mtime`/`size` (or non-existence) before
   the safety check, re-stat just before approving, and bail on any change.
   Closes the same-process race between our git snapshot and `callback`.
5. **Cache precedence.** A cached `reject_always` (`_always_cache`) wins over
   a would-be-safe trust check — trust runs after the cache.
6. **Wide-scope WARN.** When the user supplies a path scope that covers
   `$HOME`, a top-level dir (`/`, `/tmp`, `/var`, …), or starts with an
   unanchored `**`, `Logger.notify` fires a WARN with the affected kinds.

Scope state lives on `PermissionManager._trust_scope` and is cleared by
`clear()` (same lifecycle as `_always_cache`). The scope display string is
also pushed into the chat panel's `vim.t.agentic_headers` so external UI
plugins can surface it via the `AgenticHeadersChanged` autocmd.

`git_files.lua` resolves the worktree's actual index path via
`git rev-parse --git-path index` (`.git/worktrees/<name>/index` for worktree
checkouts, plain `.git/index` otherwise) and uses that for mtime-based cache
invalidation of the tracked-files set.

Controlled by `Config.auto_approve_trust_scope` (default `true`). When false,
`/trust` is rejected and the trust check is skipped entirely.

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

**Extmark gravity is critical.** The button extmark must use `right_gravity=true`
and `end_right_gravity=true`. Without this, `update_tool_call_block` can corrupt
the extmark position: `nvim_buf_set_lines(buf, start, end, ...)` with an
exclusive `end` that lands exactly on the button extmark's start row causes the
extmark to collapse into the replacement range when `right_gravity=false`
(default). `remove_permission_buttons` then deletes tool call block content
instead of just the buttons. This manifests as parallel tool calls disappearing
— only the first block survives because subsequent blocks are removed along with
the buttons after the first block's update triggers a reanchor cycle.

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

### `thought_level` ConfigOption not emitted (claude-agent-acp)

The ACP schema reserves `thought_level` as a `SessionConfigOptionCategory`
alongside `mode` and `model`, and the Anthropic SDK exposes per-model effort
capability (`low | medium | high | max`). But `claude-agent-acp` 0.29.0 does not
construct a `thought_level` ConfigOption — `buildConfigOptions` in
`dist/acp-agent.js:1250-1279` returns only `mode` and `model`.

The plugin's `AgentConfigOptions:set_options` already dispatches on
`category == "thought_level"` (`agent_config_options.lua:80-81`), so the moment
the bridge starts emitting it no adapter changes are needed. A
`/effort`-equivalent selector is blocked on that upstream change — building it
now against `_meta.claudeCode.options.maxThinkingTokens` would only work at
session creation, which diverges from the TUI's dynamic `/effort` and is not
recommended. See
`@.claude/skills/acp/references/claude-agent.md` § "ConfigOptions —
`thought_level` not emitted".

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

**Detection signal on the first turn.** `usage.totalTokens == 0` on the first
response of a session is an unambiguous auth-rejection signal — zero input
tokens means the request was rejected before tokenisation, and on the first
turn there is no prior state that could cause a legitimate zero (no stall, no
cancelled turn, no re-use of a stale generator).

**Not reliable mid-session.** Zero-usage responses do appear mid-session in
otherwise-working sessions (cause not fully characterised — possibly stalled
generators per "Prompt loop stall", or cancelled turns reusing the prompt
loop). Treating them as errors produces false positives that contradict the
visible chat state.

**Surfacing rule** (implemented as `Recovery.surface_unexpected_response`
in `session_recovery.lua`, called from the `send_prompt` success branch
in `_handle_input_submit_inner`): render
`response.stopReason` + `response.usage` verbatim when `stopReason ~=
"end_turn"` every turn, OR when `usage` is all-zero **on the first turn
only**. The first-turn gate uses `_is_first_message` captured as a local
before the system-info injection flips it. Render provider fields
only — never synthesise "no response" messages or speculate about cause.
Chat emptiness after the thinking indicator clears is self-evident and does
not need a client-generated explanation.

**Exclude `cancelled`.** `stopReason: "cancelled"` is the protocol-level
acknowledgement of the user pressing Ctrl-C (which fires `session/cancel`).
It is the *expected* response shape for that user action, not a provider
fault — surfacing it would render an "Error" block for every cancelled
turn. Skip it before evaluating the non-terminal/zero-first-turn rule.
Other non-`end_turn` reasons (`max_tokens`, `max_turn_requests`, `refusal`)
are provider-initiated and remain surfaced. See SKILL.md §
"Stop reasons" for the full enumeration and which are user-initiated.

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
