# Plan: one reading of `OpenOpts` in `init.lua`
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/init.lua` — `agentic.OpenOpts`, `Agentic.open`,
  `Agentic.new_session`
- Tests: `lua/agentic/bootstrap.test.lua` (`open()`),
  `tests/integration/send.test.lua` (`new_session({ auto_add_to_context =
  false })`)

## Background
`Agentic.open` and `Agentic.new_session` apply `agentic.OpenOpts` to a session with the same
lines: add the selection or file unless `auto_add_to_context` is false,
then `widget:show(opts.mods, SessionRegistry.target_win())`.
`NewSessionOpts` extends `OpenOpts`, so a new `OpenOpts` field must be
read in both places. They differ only in how they get the session
(`get_or_create` vs `create`).

## Changes
1. `init.lua`: new local `open_session` (Additions), above `Agentic.open`.
2. `Agentic.open`: after the nil check, `open_session(session, opts)`.
3. `Agentic.new_session`: `if session then open_session(session, opts) end`.

## Additions
### `init.lua`
```lua
--- Add the current selection or file to `session`'s context unless
--- `opts.auto_add_to_context` is false, then show its chat.
--- @param session agentic.SessionManager
--- @param opts agentic.OpenOpts
local function open_session(session, opts)
```

### Tests
No new test: the function is local, and `bootstrap.test.lua` (default
opts through `open`) and `send.test.lua` (`auto_add_to_context = false`
through `new_session`) cover both callers. Both pass unchanged.

## Expected outcome
No change in behaviour.

## Non-goals
- `SessionResume.resume`, which shows a chat with `mods` only and has no
  `OpenOpts`.

## Open questions
None.
