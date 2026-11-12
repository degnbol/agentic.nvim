# Plan: session/load waits for a ready client
Status: reviewed spec

## Relevant files
- `lua/agentic/session_manager.lua` — `load_acp_session`, the on-ready
  callback in `SessionManager:new`, `_do_load_acp_session`
- `lua/agentic/session_manager.test.lua` — "defers a load until the agent is
  ready" (`_do_load_acp_session: load state`)
- `tests/integration/test_session_load.lua` — "loads a file under its name
  and sends its ACP id" calls `load_acp_session` directly
- `lua/agentic/session_resume.lua` — `SessionResume.resume` (only caller)
- `lua/agentic/acp/acp_client.lua` — `when_ready`, `_apply_initialize_result`
- `lua/agentic/acp/agent_instance.lua` — `get_instance`
- Skills: `session-lifecycle` (race 1), `provider-system`

## Background
`load_acp_session` sends `session/load` at once when
`self.agent.agent_capabilities` is set, else it stores `_pending_load` for the
on-ready callback. `_apply_initialize_result` sets `agent_capabilities` and
nothing clears it. So the load goes out on a client that is not ready:

- during the startup `authenticate` (state `initializing`, capabilities set);
- on a client that was ready, whose process died, while `get_instance`
  restarts it (no session subscribed) or the transport reconnects it
  (provider `reconnect` set);
- on a client that was ready, whose process died, that nothing restarts:
  sessions are still subscribed and `reconnect` is off (the default). Only
  `SessionRecovery.restart_client` (after a re-login) or a later
  `get_instance` with no session subscribed starts it again.

The `session/load` then goes before the configured `auth_method` has run, or
to a dead or restarting process, where it fails at the stop. The docstring
says the load waits "if the agent isn't ready yet": the check does not match
it.

The only caller outside tests is `SessionResume.resume`, which calls it on the session that
`SessionRegistry.create` just made. That session's on-ready callback is
always queued with the client (`get_instance` → `when_ready`, or run at once
for a ready client). So a deferred load always has a callback to run it. When
the client is ready, the on-ready body is scheduled and runs after the load,
where `_load_state` stops it (race 1 in the `session-lifecycle` skill).
Only that session's own on-ready runs a deferred load: on an older session
whose on-ready already ran, `_pending_load` would wait forever.

`restart_client` while a load waits: `go_ready` runs the waiters first, so
the session's on-ready runs `_do_load_acp_session`, which advances its
epoch, and the renew loop scheduled by the restart's callback skips it.

## Changes
`lua/agentic/session_manager.lua`, `load_acp_session`: the condition becomes
`self.agent and self.agent.state == "ready"`. Docstring: replace "(fresh
SessionManager)" with a stated precondition: call it on a session whose
on-ready callback has not run (one just created).

`lua/agentic/session_manager.test.lua`:
- `make_load_session`'s agent gets `state = "ready"`.
- "defers a load until the agent is ready": set `state = "initializing"`
  and keep `agent_capabilities` set, instead of clearing
  `agent_capabilities`.
- New: "loads at once on a ready agent": `load_acp_session` sends
  `session/load` (`captured_load_cb` set) and leaves `_pending_load` nil.

`tests/integration/test_session_load.lua`, `before_each`: set
`_G.s.agent.state = "ready"` next to `agent_capabilities`. The mock
transport never reaches `ready`, so without it "loads a file under its name
and sends its ACP id" defers the load and `_G.load_cb` is nil.

## Expected outcome
A resume on a client that is not `ready` stores `_pending_load`, and the
session's on-ready callback sends `session/load` once the client is ready.
A resume on a ready client loads at once, as today.

A resume on a dead client that nothing restarts (sessions still subscribed,
`reconnect` off) waits with an empty chat until a restart, as a new session
on that client already does. Today the load fails at once and falls back to
the saved history. This case has not been seen in use, so it gets no state
list of its own.

## Non-goals
- Other requests sent before ready from a session's own actions (prompts,
  `new_session` from `/new`) on a client that died after it was ready.
- Clearing `agent_capabilities` when a process stops.
- A notice while a session waits on a client that does not start.

## Open questions
None.
