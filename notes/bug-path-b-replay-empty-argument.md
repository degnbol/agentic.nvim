# Bug: Path B replays tool calls with an empty argument

Line numbers against `cc07515` + working tree.

## Mechanism

`ChatHistory.prepend_restored_messages` gates on the argument being present
(`chat_history.lua:236`):

```lua
elseif msg.type == "tool_call" and msg.argument then
    local tool_text = string.format("Tool call (%s): %s", msg.kind or "unknown", msg.argument)
```

An empty string is truthy in Lua, so a record with `argument = ""` passes the gate
and produces `Tool call (read): ` — a kind and a result body with nothing naming
what the call operated on. A record with `argument = nil` fails the gate, and the
whole entry, result body included, is dropped.

The persisted `argument` is the initial `tool_call`'s value, merged with any
`argument` on later updates (`SessionManager:_on_tool_call_update`). The base
`ACPClient:__build_tool_call_update` sets only `tool_call_id`, `status`, `body`
and `failure_reason` (`acp_client.lua:815-826`), so for an adapter that does not
replace it, `argument` stays at the initial `update.title` — `""` or nil when the
provider sent an empty or absent title. Claude, codex and mistral override
`__build_tool_call_update`, and opencode overrides `__handle_tool_call_update`;
gemini, cursor and auggie use the base.

## Fix

Do **not** tighten the gate to `msg.argument ~= ""`. That drops the whole entry,
including the result body, from the replayed prompt — the model loses the tool's
output as well as its target, which is strictly worse than an unlabelled call.

Emit the entry with a fallback instead, for both `""` and nil. Candidates, in
preference order:

1. `msg.description` when non-empty — for execute calls this is the model's own
   one-line summary and is often more useful than the raw command.
2. The kind alone, with the argument segment omitted rather than rendered as a
   dangling `: ` (`Tool call (read)` + `\nResult:\n…`).

Reserve a literal placeholder for neither — `unknown` or `?` in the argument slot
reads as though the tool operated on a file by that name.

## Verifying first

No session file on disk is known to exercise this case. Before changing the
gate, confirm a base-builder provider actually persists `""` or nil — drive one
`read` call through gemini or cursor and inspect the saved JSON. If their initial
`tool_call` always carries a usable title, this is a robustness fix rather than a
live bug.
