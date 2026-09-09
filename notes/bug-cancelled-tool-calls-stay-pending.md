# Bug: cancelled tool calls keep their pending footer forever

## Observed

`<C-c>` during a tool call leaves that block's footer showing its non-final
status for the rest of the session — and after restore, since the status is
persisted with the block.

## Cause

`Agentic.stop_generation` (`init.lua:298-309`) flips `is_generating`, stops the
status indicator and clears the permission manager. It touches no tool-call
blocks, and `finalize_turn` (`message_writer.lua:659-675`) does not either.
Whether the provider sends a late `tool_call_update` for a call it abandoned is
provider-dependent, so in practice nothing refreshes those footers.

The stale status persists: `add_message` records it (`session_manager.lua:1003`),
and on cancel `err == nil`, so the save branch at `:1963` runs. Restore replays
it at `session_restore.lua:352`.

## Fix

A named `MessageWriter` method that walks its own `tool_call_blocks` filtered to
non-final statuses. Three constraints:

- **Not inline at the cancel site.** `tool_call_blocks` accumulates for the whole
  session and both writers have one, so the walk belongs on the writer.
- **Push each block through `SessionManager:_on_tool_call_update`**, which already
  does buffer + history + permission cleanup. Rewriting only the buffer leaves the
  persisted status stale, so the symptom would survive restore even after the fix.
- **Only rewrite non-final statuses**, so a genuine late update from the provider
  still wins.

Needs a status word. `cancelled` is in neither `status_icons`
(`config_default.lua:331-335`) nor `theme.lua`'s `status_hl` (which falls back to
`Comment`) — add one, or reuse `failed`.

Note `in_progress` has no `status_icons` entry either, so a stale footer may
render as ` in_progress` rather than `󰔛 pending` depending on what the provider
last sent. Worth fixing in the same pass.
