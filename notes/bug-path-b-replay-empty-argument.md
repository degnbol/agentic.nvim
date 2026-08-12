# Bug: Path B replays tool calls with an empty argument

Line numbers against `3f548f7`. Split out of
`notes/bug-chat-history-drops-tool-call-enrichment.md`, which fixes why `argument`
is empty for the claude provider; this note is the remaining case where it is
empty legitimately.

## Mechanism

`ChatHistory.prepend_restored_messages` gates on the argument being present:

```lua
elseif msg.type == "tool_call" and msg.argument then
    local tool_text = string.format("Tool call (%s): %s", msg.kind or "unknown", msg.argument)
```

An empty string is truthy in Lua, so a record with `argument = ""` passes the gate
and produces `Tool call (read): ` — a kind and a result body with nothing naming
what the call operated on. `SessionRestore` also coerces nil to `""` on replay
(`session_restore.lua:349`), so the empty form propagates rather than staying nil.

This survives the enrichment fix for any provider whose adapter does not override
`__build_tool_call_update`. The base implementation sets only `tool_call_id`,
`status`, `body` and `failure_reason` (`acp_client.lua:667-677`), so `argument`
keeps whatever the initial `tool_call` carried — `""` when the provider sent a
placeholder or empty title. Only claude, codex and mistral override it; gemini,
cursor and auggie do not.

## Fix

Do **not** tighten the gate to `msg.argument ~= ""`. That drops the whole entry,
including the result body, from the replayed prompt — the model loses the tool's
output as well as its target, which is strictly worse than an unlabelled call.

Emit the entry with a fallback instead. Candidates, in preference order:

1. `msg.description` when non-empty — for execute calls this is the model's own
   one-line summary and is often more useful than the raw command.
2. The kind alone, with the argument segment omitted rather than rendered as a
   dangling `: ` (`Tool call (read)` + `\nResult:\n…`).

Reserve a literal placeholder for neither — `unknown` or `?` in the argument slot
reads as though the tool operated on a file by that name.

## Verifying first

No session file on disk currently exercises the surviving case: every `argument = ""`
record in the sample sessions comes from the claude provider, which the enrichment
fix repairs. Before changing the gate, confirm a non-overriding provider actually
persists `""` — drive one `read` call through gemini or cursor and inspect the
saved JSON. If their initial `tool_call` always carries a usable title, this is a
robustness fix rather than a live bug.
