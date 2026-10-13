# Bug: codex/gemini read `content[1]` as a diff without checking its type

Unverified — found by reading, not reproduced. Neither provider was exercised.
Line numbers against `cc07515` + working tree.

## Mechanism

`ACPClient:find_content_diff` scans `content[]` for the `{type="diff"}` entry.
Three adapters do not use it. They index `content[1]` directly when they build
the message for the initial `tool_call`:

| adapter | method | index assumed | checks `type` |
| --- | --- | --- | --- |
| `codex_acp_adapter.lua:52` | `__handle_tool_call` | 1 | no |
| `gemini_acp_adapter.lua:31` | `__handle_tool_call` | 1 | no |
| `mistral_vibe_acp_adapter.lua:41` | `__build_tool_call_message` | 1 | yes (`:43`) |

Mistral's type check makes a non-diff entry at `[1]` a no-op, so only the index
assumption is at risk there. Codex and gemini read `newText`/`oldText` off
whatever entry sits at `[1]`. If that is a `{type="content"}` status-text entry
— the layout opencode uses on write/edit completion — both fields are nil,
`safe_split(nil)` returns `{}`, and `message.diff` becomes `{new={}, old={}}`.

An empty `old` is not inert: `ToolCallDiff.extract_diff_blocks` substitutes the
whole file for it when the file is readable (`tool_call_diff.lua:62`), then
diffs that against an empty `new`. The block renders as a deletion of every
line. `MessageWriter:update_tool_call_block` does not re-render a block that
already has a diff (`already_has_diff`, `message_writer.lua:2840`), so later
updates cannot correct it.

## Fix

Replace the `content[1]` read with `self:find_content_diff(update)` in all
three. Codex and gemini gain the type check; mistral loses a redundant one.

## Verifying first

Whether either bridge ever puts a non-diff entry at `[1]` of an `edit`-kind
`tool_call` is unknown — the symptom above only fires if it does. Log
`update.content` on the initial `tool_call` from each provider before changing
anything; if the diff is always at `[1]`, this is a robustness fix rather than
a live bug.
