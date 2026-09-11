# Plan: cancelled tool calls get a `cancelled` footer

Line numbers are against `8fb00a4`.

## Background

`<C-c>` while a tool call is awaiting permission leaves that block's footer
showing `pending` (or `in_progress`) for the rest of the session, and after
restore too.

`Agentic.stop_generation` (`lua/agentic/init.lua:298-302`) delegates to
`SessionManager:stop_generation` (`lua/agentic/session_manager.lua:2077-2085`),
which sends `session/cancel`, clears the permission manager and stops the
indicator. It touches no tool-call blocks, and `_finalize_turn` (`:1426-1435`)
does not either. Whether the provider sends a late `tool_call_update` for a call
it abandoned is provider-dependent, so nothing refreshes those footers.

The stale status is persisted: `add_message` records it (`:1057`), on cancel
`err == nil` so the save branch at `:2640-2647` runs, and restore replays it at
`lua/agentic/session_restore.lua:352`.

## Changes

### `MessageWriter:nonfinal_tool_call_ids()`

New query in `lua/agentic/ui/message_writer.lua`. No arguments; returns the ids
in `self.tool_call_blocks` whose status fails the file-local `is_final_status`
(`:48-50`).

Reuse that predicate rather than whitelisting `{pending, in_progress}`, which
would miss a `status == nil` tracker — adapters may pass one through
(`lua/agentic/acp/acp_client.lua:633`).

Return a collected list, not a live iterator: `update_tool_call_block` deletes
entries from `tool_call_blocks` on its collapsed-extmark bail-out (`:2350`), and
each update resizes the buffer.

### `SessionManager:_cancel_unresolved_tool_calls()`

New method in `lua/agentic/session_manager.lua`. No arguments. Called from the
`send_prompt` callback (`:2519`) under `response.stopReason == "cancelled"`,
immediately before `self:_finalize_turn(turn_usage)` (`:2610`). That position
sits below the epoch guard (`:2539-2541`), above `chat_history:save()`
(`:2640-2647`), and above `status_indicator:stop()` (`:2621`) — all three are
required.

The callback fires because `stop_generation` sends `session/cancel`
(`lua/agentic/acp/acp_client.lua:1095-1103`) *and* `permission_manager:clear()`
resolves the outstanding permission request with `nil`
(`lua/agentic/ui/permission_manager.lua:949-968`). The docstring at
`session_manager.lua:2073-2074` already states this.

For each writer, for each id from `nonfinal_tool_call_ids()`:

```lua
writer:update_tool_call_block({ tool_call_id = id, status = "cancelled" })
```

and for `self.message_writer` only, also

```lua
self.chat_history:update_tool_call(id, {
    type = "tool_call", tool_call_id = id, status = "cancelled",
})
```

Subagent interim is not restored, so `self.subagent_writer`'s ids are
buffer-only — the same split `_on_tool_call_update` makes at `:1449`.

Both calls are status-only-safe: `update_tool_call_block` merges with
`vim.tbl_deep_extend("force", tracker, tool_call_block)`
(`message_writer.lua:2282`) and `ChatHistory:update_tool_call` with the same
(`lua/agentic/ui/chat_history.lua:129`), so `body`, `diff` and `argument`
survive.

Call `update_tool_call_block` directly rather than routing through
`_on_tool_call_update`, which also restarts the indicator (`:1535-1541`), runs
`_try_record_edit_range` (`:1445`), and re-opens cancelled Tasks. The permission
cleanup that would have justified the funnel is already done by
`permission_manager:clear()`, and `_open_tasks` is cleared at `:2618`.

### `cancelled` status

`message_writer.lua:2367` re-renders a diff block when `status == "failed"`, on
the premise that a failed mutation never hit disk. A cancellation can have hit
disk mid-flight, so `cancelled` must take the highlight-only path instead.

- `is_final_status` accepts it (`message_writer.lua:48-50`); both fold gates
  (`:2180`, `:2516`) and the restore replay read it.
- `agentic.ui.ToolCallStatus = agentic.acp.ToolCallStatus | "cancelled"`; type
  `ToolCallBase.status` (`message_writer.lua:77`) with it. The wire enum
  (`lua/agentic/acp/acp_client.lua:1207-1211`) stays at four values.
- `status_hl` entry (`lua/agentic/theme.lua:46-51`, fallback is `Comment` at
  `:239`), `status_icons` entry (`lua/agentic/config_default.lua:349-353`), and
  the enumeration at `doc/agentic.txt:434`.

## Tests

- `lua/agentic/ui/message_writer.test.lua` — `nonfinal_tool_call_ids` returns
  ids whose status is `pending`, `in_progress` or `nil`, and omits
  `completed`/`failed`/`cancelled`.
- `lua/agentic/ui/message_writer.test.lua` — a `cancelled` update on a block that
  already has a diff leaves the rendered diff lines untouched (the `failed` path
  re-renders).
- `lua/agentic/session_manager.test.lua` — a `send_prompt` callback with
  `stopReason = "cancelled"` stamps every non-final block and writes the status
  to `chat_history` for the main writer only.
- `lua/agentic/theme.test.lua` — `get_status_hl_group("cancelled")` is not the
  `Comment` fallback.

## Expected outcome

A footer reading `pending`/`in_progress` when the turn is cancelled reads
`cancelled` instead, live and after restore. Nothing else changes.

## Non-goals

- Turns that end with `err ~= nil`, which strand the same blocks.
- Any new chat text — the footer word is the only visible change.
- Per-turn scoping. The predicate is "status is currently non-final", so
  parallel executions are covered without it.
- A second sweep in `_refresh` (`session_manager.lua:653`) for a provider that
  never answers the cancelled prompt.
- Glyphs for the statuses that have none — see
  [`bug-in-progress-has-no-status-glyph.md`](bug-in-progress-has-no-status-glyph.md).
