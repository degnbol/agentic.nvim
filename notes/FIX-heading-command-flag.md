# Plan: Guard a heading whole when the adapter knows it is a command
Status: reviewed spec — on hold, no reproducer
Priority: P3
Depends: FIX-placeholder-titles.md

No provider path puts a shell command in the generic head today:
claude-agent-acp kinds Bash `execute` and Grep/Glob `search` (Monitor, also
with a `command` input, heads with its `description` via
`ClaudeUtils.tool_head`); opencode the same; codex-acp defaults commands to
`execute` (or `read`/`search` from `parsed_cmd`). Only an unknown tool with a
`command` input reaches the generic branch, and that value need not be a
shell command. Auggie is unverified.

After `FIX-placeholder-titles.md` (still a draft): its change 8 makes the
Claude adapter's generic head the tool name, never a command or title, so the
Claude adapter needs no flag.

## Relevant files
- `lua/agentic/ui/message_writer.lua` — `ToolCallBase`; tracker merge (`tbl_deep_extend`) in `MessageWriter:update_tool_call_block`
- `lua/agentic/ui/tool_call_layout.lua` — `CODE_KINDS`, `collapsed_header`, `default_head` (the generic branch), `HEADS`
- `lua/agentic/acp/canonical_tool_call.lua` — `normalise`, applied to every message in `SessionManager:_on_tool_call` and `SessionManager:_on_tool_call_update`
- `lua/agentic/ui/chat_history.lua` — `TOOL_CALL_FIELDS` (the persisted fields)
- `lua/agentic/acp/adapters/{auggie,codex,opencode}_acp_adapter.lua`
- Skills: `provider-system`, `rendering`

## Background
The generic heading bucket cannot be typed by kind: adapters fill `argument`
from `rawInput.command` or from `update.title` under the same kind (see
`CODE_KINDS` docstring). A command there renders as prose, and a prose
heading guards only the words that hold a markdown-special character
(`MarkdownGuard.words_within`), so `rg '_x_' src` shows `rg` bare and `_x_`
as code. The user's rule: a known command is always guarded whole.

The adapter knows which source it used at the assignment site. Carrying that
as a field is the only place the fact exists; the renderer cannot recover it.

The tracker merges updates with `tbl_deep_extend`, so a field omitted from an
update keeps its old value: a title-only update after a command update would
keep a stale `true`. One default in the canonical form closes that for every
adapter, so adapters only ever write `true`.

## Changes

### `lua/agentic/ui/message_writer.lua`
- `ToolCallBase`: `--- @field argument_is_command? boolean The argument is a shell command, not prose. False when a message sets the argument without saying.`

### `lua/agentic/acp/canonical_tool_call.lua`
- `normalise(message, kind)`: when `message.argument ~= nil` and
  `message.argument_is_command == nil`, set `argument_is_command = false`.
  Update the docstring sentence "Fields the message lacks stay absent".
- `SessionManager:_apply_side_tool_call` bypasses `normalise`; its updates
  come from Claude side records, which never set `true`, so no stale value
  survives them.

### Adapters — set `argument_is_command = true` where `argument` is a command
- `AuggieACPAdapter:__handle_tool_call`, final `else` branch: compute
  `__ensure_command_string(update.rawInput.command)` first; `true` when
  non-nil.
- `CodexACPAdapter:__handle_tool_call`, `elseif update.rawInput` branch:
  `true` for `parsed_cmd[1].cmd` and for a non-nil
  `__ensure_command_string(...)`.
- `OpenCodeACPAdapter:__handle_tool_call_update`, `rawInput.command` branch:
  `true`.

Every other `argument` write gets `false` from `normalise`. Kinds with their
own head (`execute` uses the description; `search`, `fetch` are `CODE_KINDS`)
ignore the flag.

### `lua/agentic/ui/chat_history.lua`
- Add `"argument_is_command"` to `TOOL_CALL_FIELDS`, so a replayed chat
  renders the same heading. Sessions saved before this change lack the field
  and render as prose.

### `lua/agentic/ui/tool_call_layout.lua`
- `collapsed_header(is_code, name, wrap_width, truncate)` — `is_code
  boolean|nil` replaces `kind`: whole-name guard when true, per-word guard
  otherwise. Callers in `HEADS` pass `CODE_KINDS[call.kind]`.
- `default_head`: pass `CODE_KINDS[call.kind] or call.block.argument_is_command`.

### Tests
- `tool_call_layout.test.lua`: generic-kind block with
  `argument_is_command = true` and argument `rg '_x_' src` →
  `` ### `rg '_x_' src` ``; same argument with the flag `false` → per-word
  guard.
- `canonical_tool_call` tests: argument without flag → `false`; flag `true`
  kept; no argument → flag stays absent.
- `opencode_acp_adapter.test.lua`: the command branch sets `true`. Auggie and
  codex have no adapter test files; add `auggie_acp_adapter.test.lua` and
  `codex_acp_adapter.test.lua` with the same case.
- Persistence: the existing `chat_history.test.lua` case "keeps every field
  ToolCallBase declares" fails until `TOOL_CALL_FIELDS` holds the new field.

## Expected outcome
- A generic-bucket head filled from `rawInput.command` renders as one code
  span, like a `search` head.
- A head filled from `update.title` follows the prose rule, also after an
  earlier command update.

## Non-goals
- Re-kinding generic calls to `execute`.
- Back-filling the flag into saved sessions.

## Open questions
None.
