# Plan: one order for session lists
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/ui/chat_history.lua` — `list_sessions`, `list_all_sessions`
- `lua/agentic/ui/chat_history.test.lua` — `describe("list_sessions")`,
  `describe("list_all_sessions")`

## Background
`list_sessions` and `list_all_sessions` sort with the same comparator: `last_activity`,
else `timestamp`, newest first. Both docstrings promise "by last activity
descending". The pickers show both lists, so the order is one rule.

## Changes
1. Add the local `by_last_activity` (Additions) above `list_sessions`.
2. Both functions call `table.sort(<list>, by_last_activity)`.

## Additions
### `chat_history.lua`
```lua
--- Sort order of session lists: newest last activity first, a session
--- without one at its creation time.
--- @param a agentic.ui.ChatHistory.SessionMeta
--- @param b agentic.ui.ChatHistory.SessionMeta
--- @return boolean
local function by_last_activity(a, b)
```

### Tests
No test checks the order today. Write first, passing on today's code: in
both `describe` blocks, write three session files, with `last_activity` 10,
with `last_activity` 30, and with none and `timestamp` 20. The list is in
the order 30, 20, 10. Write the JSON directly, as the `write` helper of
"keeps one row per id, the file with the newer mtime" does: `save` stamps
`last_activity = os.time()`. Existing cases pass unchanged.

## Expected outcome
No behaviour change.

## Non-goals
- `newest_per_id`, which orders files by mtime.
- The session meta files of `notes/PERF-append-session-log.md`.

## Open questions
None.
