# Bug: persisted tool calls lose `failure_reason`, `read_range`, `search_pattern`

Line numbers against `cc07515` + working tree. The live chat buffer renders
correctly — the defect is in the session file and in what a restore replays
from it.

## Mechanism

Three separate hand-picked projections of `agentic.ui.MessageWriter.ToolCallBase`
exist. All three drop the same three render fields:

| site | direction |
| --- | --- |
| `SessionManager:_on_tool_call`, `session_manager.lua:1971-1985` | block → record (add) |
| `SessionManager:_on_tool_call_update`, `session_manager.lua:2462-2473` | update → record |
| `SessionRestore.replay_messages`, `session_restore.lua:387-398` | record → block (Path A replay) |

`agentic.ui.ChatHistory.ToolCall` is declared as
`: agentic.ui.MessageWriter.ToolCallBase` (`chat_history.lua:21`), so all three
contradict the type they claim to build. The fields never persisted:

| dropped field    | set by                                             | what it holds                                    |
| ---------------- | -------------------------------------------------- | ------------------------------------------------ |
| `failure_reason` | `ACPClient:__build_tool_call_update`, claude adapter | error text shown in place of the body on failure |
| `read_range`     | `ClaudeAgentACPAdapter:__apply_raw_input`          | line range of a partial read                     |
| `search_pattern` | claude and opencode adapters                       | regex for highlighting search output             |

MessageWriter's tracker receives them, so the live display is right. The
history never holds them, so Path A replay renders a failed call without its
reason (`tool_call_renderer.lua:1007`), a partial read without its range, and
search output without match highlighting.

Session `3d52d090-c060-427c-b45b-b85fe9303755.json` under
`~/.cache/nvim/agentic/sessions/Users_cmadsen_dotfiles_config_nvim_modules_agentic.nvim_e91a38a6/`
shows the effect: no record carries any of the three fields, including the three
`execute` calls persisted as `status: "failed"`.

## Fix

Move the projections into `ChatHistory`, which declares the record type. Today
`SessionManager` decides twice which fields survive, and `SessionRestore` a third
time; one list in the owning module replaces three in its consumers.

**Update site** (`session_manager.lua:2462-2473`) — delete the local and pass the
update through, retyping `ChatHistory:update_tool_call`'s `@param update` to
`agentic.ui.MessageWriter.ToolCallBase`:

```lua
self.chat_history:update_tool_call(id, tool_call_update)
```

The `{ type = "tool_call", tool_call_id = id }` wrapper is dead weight:
`update_tool_call` only ever merges into a record that already carries both keys
(added by the add site), and `id` is `tool_call_update.tool_call_id` by
construction (`:2443`). The pass-through also persists `file_created` and
`hunk_ranges`. See the open question.

**Add site** (`session_manager.lua:1971-1985`) — call a whitelist in `ChatHistory`,
`tool_call_record(block)`, returning `type` plus all `ToolCallBase` fields. Keep
`parent_tool_use_id = parent` outside it: the add site derives it from the
subagent owner, not from the block.

**Replay site** (`session_restore.lua:387-398`) — call the inverse,
`ChatHistory.to_tool_call_block(msg)`. It must keep the existing
`argument = msg.argument or ""` coercion, since `ToolCallBlock` declares `kind`
and `argument` non-optional. Without this site the newly persisted fields are
written to disk and then discarded on replay.

### Why the update site may be spread but the add site may not

Not because of the `ToolCallBase`/`ToolCallBlock` `@class` split — a LuaCATS
annotation constrains nothing at runtime. The asymmetry is in how MessageWriter
treats each argument:

- `MessageWriter:write_tool_call_block` stores *the block it was given* as the
  tracker (`message_writer.lua:2753`), and stamps `decoration_extmark_ids`
  (`:2714`), `extmark_id` (`:2741`) and — via `Renderer.prepare_block_lines` —
  `search_matches`, `search_ansi`, `cached_diff_blocks` onto it. All of that
  lands before the add-site literal runs, so spreading there would write extmark
  ids and render caches into the session JSON. Hence the whitelist.
- `MessageWriter:update_tool_call_block` merges into a *new* table
  (`tracker = vim.tbl_deep_extend("force", tracker, block)`,
  `message_writer.lua:2843`) and mutates its argument only as `body = nil`
  (`:2826`). The update message is never handed over as a tracker, and every
  adapter builds it as a fresh literal of `ToolCallBase` keys only
  (`ACPClient:__build_tool_call_update`, the claude/codex/mistral overrides,
  `OpenCodeACPAdapter:__handle_tool_call_update`). Hence the pass-through is
  safe.

`ChatHistory:update_tool_call` merges via `vim.tbl_deep_extend("force", msg,
update)` (`chat_history.lua:198`). A field absent from a partial update is not a
key in the table at all, so it cannot clobber an accumulated value with nil.

## Test

Merge semantics have a describe block at
`lua/agentic/ui/chat_history.test.lua:382` (`update_tool_call`); a
session-wiring stub that runs the real `_on_tool_call` against a real
`ChatHistory` is at `lua/agentic/session_manager.test.lua:3680` (`permission
deciders`).

Assert the properties, not just the symptom:

1. A `failed` call persists `failure_reason`; a partial read persists
   `read_range`; a search persists `search_pattern`. Path A replay renders each.
2. A subsequent update carrying only `{ tool_call_id, status = "completed" }`
   leaves `argument` and `kind` intact. This is the non-clobber property the
   pass-through depends on.
3. A persisted record contains none of `extmark_id`, `decoration_extmark_ids`,
   `search_matches`, `search_ansi`, `cached_diff_blocks`. This is what breaks if
   the spread is ever migrated to the add site.

Beware asserting that a persisted `body` equals the rendered body: `tbl_deep_extend`
replaces a list-valued key wholesale, whereas `update_tool_call_block` appends
previous + `---` + new (`message_writer.lua:2845-2855`). The divergence is out of
scope here.

## Open question

The `hunk_ranges` docstring (`message_writer.lua:116`) says the range survives
a session restore. Today no history payload persists it, so the docstring is
false. Decide which is wrong:

- Persist it. The update pass-through does so, and the replay site must then
  pass it to the block. Test 1 gains a `hunk_ranges` case.
- Do not persist it. Correct the docstring, and keep the pass-through from
  writing it (and `file_created`) to the record.

## Not addressed

`ChatHistory.prepend_restored_messages` gates on `msg.argument`, and an empty
string is truthy in Lua — see `notes/bug-path-b-replay-empty-argument.md`.
