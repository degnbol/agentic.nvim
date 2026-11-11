# Bug: get_instance calls on_ready on a client that is still starting
Status: draft

## Relevant files
- `lua/agentic/acp/agent_instance.lua` — `get_instance`, cached-client branch
- `lua/agentic/acp/acp_client.lua` — `_connect` (`go_ready`), `restart`
- `lua/agentic/skeptic/init.lua` — `Skeptic:enable`, one `BackgroundSession` per skeptic in one loop
- `lua/agentic/background_session.lua`, `lua/agentic/session_manager.lua` — `get_instance` callers

## Background
`get_instance` calls `on_ready` at once for a cached client unless it
restarts it. `_connect` runs synchronously up to the `initialize` request, so
a client created moments before is `connecting` or `initializing`. A second
caller then gets `on_ready` before `go_ready`, and its `session/new` goes out
before the `initialize` answer. The same holds after a restart: the
restarting caller waits, the next caller does not.

`Skeptic:enable` hits this on every enable: the default config has two
skeptics, both on the unattended opencode process, which the first creates.
Main sessions hit it when two start on one provider before its first
`initialize` answer. Whether opencode or other providers reject or queue a
`session/new` before `initialize` is unmeasured.

## Changes
- `ACPClient`: a list of one-shot ready waiters, drained in `go_ready`.
- `get_instance`: call `on_ready` at once only when the state is `ready`;
  queue it in any other live state.
- Decide what a waiter gets when its start fails (`error` state): today a
  failed start never calls `on_ready`, and callers time out.

## Expected outcome
No caller of `get_instance` sends a request before its client is `ready`.

## Open questions
- Whether a dead client with subscribers should queue `on_ready` until its
  session's recovery restarts it, or keep calling it at once.
