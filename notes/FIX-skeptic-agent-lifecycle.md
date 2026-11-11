# Plan: Skeptic agents restart themselves; `/skeptic restart` goes
Status: spec

## Relevant files
- `lua/agentic/skeptic/init.lua` (+ `init.test.lua`) — `Skeptic:enable/disable/restart/command`, `_on_session_changed`, `M.setup` description
- `lua/agentic/skeptic/gate.lua` (+ `gate.test.lua`)
- `lua/agentic/background_session.lua` (+ `.test.lua`) — `destroy()`, `Opts`
- `lua/agentic/config_default.lua` — `skeptic.gate`
- `doc/agentic.txt` § `agentic-skeptic`, and the `/skeptic` line in the command list

## Background
`/skeptic restart` is `disable()` then `enable()`, the same as `off` then
`on`. It exists because the `Skeptic` module never learns that one of its
agents stopped: the dead agent stays in `_agents` and `/skeptic` still says
"on". The fix: the module restarts an agent that stops while the skeptic is
on. Then `restart` has no use. On/off stay separate commands (no toggle).

`gate` names the rule for which refuted claims go to the main agent; the
name says nothing about that. It becomes `reporting_criteria`.

## Changes

### `background_session.lua`
- `Opts` gains `--- @field on_destroy? fun() Called at the end of destroy()`.
- `destroy()`: last line `if self._opts.on_destroy then self._opts.on_destroy() end`.

### `skeptic/init.lua`
- Agent start moves into `Skeptic:_start(spec)`: creates the agent with
  `on_destroy = function() self:_on_agent_destroyed(agent) end`, adds it to
  `_agents` when `BackgroundSession:new` returns one.
- `Skeptic:_on_agent_destroyed(agent)`: when `agent` is still in `_agents`
  (it is not during `disable()`, which empties `_agents` first), replace it
  by `_start(agent.spec)` — scheduled with `vim.schedule`, so the restart
  does not run inside the destroy.
- `Skeptic:restart()` removed; `_on_session_changed` calls `disable()` then
  `enable()`.
- `command`: drop `restart`; usage `/skeptic [on|off]`. `M.setup`
  description to match.
- `Config.skeptic.gate` → `Config.skeptic.reporting_criteria`.

### `skeptic/gate.lua`
- Rename the module to `skeptic/reporting_criteria.lua` (and its test), and
  the `gate` parameters to `criteria`.

### `config_default.lua`, `doc/agentic.txt`
- `gate` → `reporting_criteria` (field, docstring, doc table).
- Doc: `/skeptic [on|off]`; drop the `restart` line; add "An agent that stops
  is started again."

### Tests
- `destroy()` calls `on_destroy`.
- An agent destroyed while on is started again with the same spec; one
  destroyed by `/skeptic off` is not.
- `restart` gives the usage notify.
- Renamed config key and module: existing gate tests pass under the new names.

## Expected outcome
- A skeptic agent that stops comes back; `/skeptic` stays truthful.
- `/skeptic` takes `on` and `off` only.
- The option reads `reporting_criteria = "agree" | "either"`.

## Non-goals
- Restart limits or back-off: not added until a restart loop is observed.

## Open questions
None.
