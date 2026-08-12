# Bug: persisted tool calls keep phase-1 `kind`/`argument`

Confirmed from persisted session data, not from reading alone. Line numbers are
against `3f548f7`. The chat buffer renders correctly — nothing on the display
path changes.

## Mechanism

Three separate hand-picked projections of `agentic.ui.MessageWriter.ToolCallBase`
exist, and each drops a different subset:

| site | direction | drops |
| --- | --- | --- |
| `session_manager.lua:995-1005` | block → record (add) | `read_range`, `search_pattern`, `failure_reason` |
| `session_manager.lua:1255-1262` | update → record | the five below |
| `session_restore.lua:347-356` | record → block (replay) | `read_range`, `search_pattern`, `failure_reason` |

`agentic.ui.ChatHistory.ToolCall` is declared as
`: agentic.ui.MessageWriter.ToolCallBase` (`chat_history.lua:19`), so all three
contradict the type they claim to build. The update-site literal carries only
`status`, `description`, `body`, `diff`, leaving five declared fields never
updated after phase 1:

| dropped field    | what it holds                                       |
| ---------------- | --------------------------------------------------- |
| `kind`           | tool kind after adapter remap (`Skill`, `SubAgent`)  |
| `argument`       | file path, command, skill name                      |
| `failure_reason` | error text shown in place of the body on failure     |
| `read_range`     | line range of a partial read                        |
| `search_pattern` | regex for highlighting search output                |

For top-level calls claude-agent-acp streams tool input separately, so the initial
`tool_call` carries empty `rawInput` and `ClaudeAgentACPAdapter:__apply_raw_input`
takes effect only on a later `tool_call_update`. That method writes `kind`,
`argument`, `read_range` (`:151-166`), `search_pattern` (`:218`), `body` and
`description` — i.e. most of what the update site discards. MessageWriter's
tracker receives the enrichment, so the display is right; the history keeps the
phase-1 values forever.

## Evidence

Session `3d52d090-c060-427c-b45b-b85fe9303755.json` under
`~/.cache/nvim/agentic/sessions/Users_cmadsen_dotfiles_config_nvim_modules_agentic.nvim_e91a38a6/`:

| persisted `kind` | persisted `argument` | what the buffer showed |
| ---------------- | -------------------- | ---------------------- |
| `other` (×4)     | `Skill`              | `### 󰒓 \`neovim\``     |
| `read` (×6)      | `""`                 | the file path          |
| `execute` (×55)  | `""`                 | the command            |

`description` survives only because it happens to sit in the literal. No record
in the file carries `failure_reason`, `read_range` or `search_pattern` — including
the three `execute` calls persisted as `status: "failed"`.

## Consequence

Path B restore (`ChatHistory.prepend_restored_messages`, `chat_history.lua:150`)
formats `Tool call (%s): %s` from `kind` and `argument`, so the replayed prompt
reads `Tool call (read): ` — a result body with no path — and skill loads replay
as `Tool call (other): Skill`. A model reconstructing context from a
Path-B-restored session cannot tell which file any Read or Edit touched.

Persisted `kind`/`argument` also feed the picker preview
(`SessionRestore.format_preview`, `session_restore.lua:239-253`) and Path A replay
rendering (`:347`). Expect newly written sessions to render differently from
sessions already on disk: a Task as `SubAgent` + `"model, subagent_type:
description"` rather than `think` + `""`, a skill load as `Skill` + the skill name
rather than `other` + `"Skill"`. No migration of existing files is planned.

## Fix

Move both projections into `ChatHistory`, which declares the record type. Today
`SessionManager` decides twice which fields survive, and `SessionRestore` a third
time; one list in the owning module replaces three in its consumers.

**Update site** (`session_manager.lua:1255-1262`) — delete the local and pass the
update through, retyping `ChatHistory:update_tool_call`'s `@param update` to
`agentic.ui.MessageWriter.ToolCallBase`:

```lua
self.chat_history:update_tool_call(id, tool_call_update)
```

The `{ type = "tool_call", tool_call_id = id }` wrapper is dead weight:
`update_tool_call` only ever merges into a record that already carries both keys
(added at `:996-997`), and `id` is `tool_call_update.tool_call_id` by construction
(`:1245`).

**Add site** (`session_manager.lua:995-1005`) — call a whitelist in `ChatHistory`,
`tool_call_record(block)`, returning `type` plus all ten `ToolCallBase` fields.

**Replay site** (`session_restore.lua:347-356`) — call the inverse,
`ChatHistory.to_tool_call_block(msg)`. It must keep the existing
`argument = msg.argument or ""` coercion, since `ToolCallBlock` declares `kind`
and `argument` non-optional. Without this site the three newly persisted fields
are written to disk and then discarded on replay.

### Why the update site may be spread but the add site may not

Not because of the `ToolCallBase`/`ToolCallBlock` `@class` split — a LuaCATS
annotation constrains nothing at runtime. The asymmetry is in how MessageWriter
treats each argument:

- `write_tool_call_block` stores *the block it was given* as the tracker
  (`message_writer.lua:1371`), then stamps `extmark_id` (`:1360`),
  `decoration_extmark_ids` (`:1325`), `ordinal` (`:976`) and — via
  `Renderer.prepare_block_lines` — `search_matches`, `search_ansi`,
  `cached_diff_blocks` (`tool_call_renderer.lua:675-715`) onto it. All of that
  lands before the add-site literal runs, so spreading there would write extmark
  ids and render caches into the session JSON. Hence the whitelist.
- `update_tool_call_block` merges into a *new* table
  (`tracker = vim.tbl_deep_extend("force", tracker, block)`,
  `message_writer.lua:1418`) and mutates its argument only as `body = nil`
  (`:1401`). The update message is never handed over as a tracker, and every
  adapter builds it as a fresh literal of `ToolCallBase` keys only
  (`acp_client.lua:667-677`, `claude_agent_acp_adapter.lua:112-126`,
  `codex_acp_adapter.lua:80-105`, `mistral_vibe_acp_adapter.lua:80-103`). Hence
  the pass-through is safe.

`ChatHistory:update_tool_call` merges via
`vim.tbl_deep_extend("force", msg, update)` (`chat_history.lua:126`). A field
absent from a partial update is not a key in the table at all, so it cannot
clobber an accumulated value with nil.

## Test

Merge semantics have a describe block at `lua/agentic/ui/chat_history.test.lua:205`;
the session-wiring stub pattern is at `lua/agentic/session_manager.test.lua:1146-1250`.

Assert the properties, not just the two symptoms:

1. A `read` call whose `argument` arrives only on the update phase persists the
   file path, not `""`; a `failed` call persists `failure_reason`.
2. A subsequent update carrying only `{ tool_call_id, status = "completed" }`
   leaves `argument` and `kind` intact. This is the non-clobber property the
   pass-through depends on.
3. A persisted record contains none of `extmark_id`, `decoration_extmark_ids`,
   `search_matches`, `search_ansi`, `cached_diff_blocks`, `parent_tool_use_id`,
   `ordinal`. This is what breaks if the spread is ever migrated to the add site.

Beware asserting that a persisted `body` equals the rendered body: `tbl_deep_extend`
replaces a list-valued key wholesale, whereas `update_tool_call_block` appends
previous + `---` + new (`message_writer.lua:1421-1430`). The divergence is
pre-existing and out of scope here.

## Not addressed

`prepend_restored_messages` gates on `msg.argument`, and an empty string is truthy
in Lua — see `notes/bug-path-b-replay-empty-argument.md`.
