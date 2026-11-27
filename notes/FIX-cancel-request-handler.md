# Plan: Handle `$/cancel_request` for permission requests
Status: spec
Priority: P2
Depends:

## Relevant files
- `lua/agentic/acp/acp_client.lua` — `_handle_notification`, `__handle_request_permission`, `ERROR_CODES.REQUEST_CANCELLED`, `ClientHandlers`
- `lua/agentic/session_manager.lua` — `_on_request_permission`, where the subscriber's handlers are built
- `lua/agentic/ui/permission_manager.lua` — `remove_request_by_tool_call_id`, `_complete_request`, `_release_request`
- `lua/agentic/acp/acp_client.test.lua`, `lua/agentic/ui/permission_manager.test.lua`
- `notes/BUG-unknown-jsonrpc-method-handling.md` — the dispatch this plan adds a branch to
- ACP SDK: `@agentclientprotocol/sdk` `dist/core/jsonrpc.js` (`$/cancel_request`, `-32800`); opencode v2.2.5 `packages/cli/src/acp/connection.ts` (`cancellationSignal` on `requestPermission`)
- Skills: `implement`, `permissions`, `provider-system`, `lua-class`

## Background
An agent sends `$/cancel_request { requestId }` when it stops waiting for
one of its requests. opencode attaches a `cancellationSignal` to every
`session/request_permission` and cancels the request when the wait is
aborted (a turn cancel, a sibling request rejected). The debug logs of
2026-11-13 have about 20 of them, all from opencode, all for permission
requests.

The plugin has no handler. Each one shows `Unknown notification method:
$/cancel_request`, and the request stays open: its float stays up, and the
user's later answer goes to a request the agent has given up. When the
cancel comes in the same tick as the request, it is processed before the
request, because `__handle_request_permission` defers the subscriber with
`vim.schedule`.

ACP cancellation is JSON-RPC's: the receiver still answers a cancelled
request, with error `-32800` (Request Cancelled) or with its result. The
plugin answers `-32800` at once, so the request has exactly one answer and
any later user answer is dropped.

## Changes
`lua/agentic/acp/acp_client.lua`:
- New field `_permission_requests: table<integer|string, agentic.acp.OpenPermissionRequest>`,
  `{}` in `new`. The class:
  ```lua
  --- @class agentic.acp.OpenPermissionRequest
  --- @field subscriber agentic.acp.ClientHandlers
  --- @field tool_call_id string
  ```
- `_connect`: reset `_permission_requests = {}` next to `_v2_states`. A new
  process restarts its ids, so an old entry must not match its cancels.
- `__handle_request_permission`: after the no-subscriber branch, store the
  entry by `message_id`. Both checks below compare identity,
  `self._permission_requests[message_id] ~= entry`, not presence: after a
  reconnect the same id can hold a new process's request. In the scheduled
  function, return when the entry is not current (cancelled before
  delivery), else call the subscriber. The
  answer callback returns when the entry is not current (cancelled after
  delivery, or a reconnect). Else it removes the entry, sends the result
  and calls `__on_permission_resolved` as today. The `pcall` error branch
  removes the entry too.
- `_send_error`, `__send_result` and the handlers' `message_id`: annotate
  `number|string`. The agent mints the ids it cancels.
- New `ACPClient:_handle_cancel_request(params)`,
  `@param params { requestId: integer|string }`. If no entry has that id
  (already answered, or not a permission request), do nothing. Else
  remove the entry, `_send_error(id, "Request cancelled",
  self.ERROR_CODES.REQUEST_CANCELLED)`, and `vim.schedule` the
  subscriber's `on_permission_cancelled(tool_call_id)`. A cancel before
  delivery needs no flag: `vim.schedule` runs in order, so the delivery
  function runs first and returns, and the removal finds no request.
- `_handle_notification`: `$/cancel_request` → `_handle_cancel_request`.
- `ClientHandlers`: new optional field
  `on_permission_cancelled? fun(tool_call_id: string)`. Optional, so a
  subscriber that answers at once (`BackgroundSession`) needs none.

`lua/agentic/ui/permission_manager.lua`: the existing
`remove_request_by_tool_call_id` already drops a request as a cancel
needs. A queued request leaves the queue with no callback. The current one
goes through `_complete_request(nil)`: `option_kind(options, nil)` is `""`,
so no always-rule and no cause is recorded. The float closes,
`_release_request` runs (keymaps, holds, layout autocmd,
`on_hidden_resolved`), and the next request opens. Its `callback(nil)`
reaches the ACP answer callback, which sends nothing because the entry is
gone. Update its docstring: it drops the request of a call the agent
stopped waiting on (a failed call, a cancelled request).

`lua/agentic/session_manager.lua`: `_build_handlers` gets
`on_permission_cancelled = function(tool_call_id)
self.permission_manager:remove_request_by_tool_call_id(tool_call_id) end`.

Tests:
- `acp_client.test.lua`:
  - A cancel after delivery: one `-32800` frame with the request's id, then
    `on_permission_cancelled` with the tool call id. A later callback sends
    nothing.
  - A cancel before the scheduled delivery: one `-32800` frame. The
    subscriber's `on_request_permission` is never called.
  - A cancel for an unknown id: nothing is sent, and there is no notice.
  - A request answered, then cancelled: one result frame and nothing else.
  - A cancel after delivery does not call `__on_permission_resolved`.
  - After `_connect`, an old request's callback sends nothing, also when
    the new process reuses its id.
- `permission_manager.test.lua`:
  - `remove_request_by_tool_call_id` of the current request closes the
    float, opens the next queued one, and records no cause or always-rule.
  - `remove_request_by_tool_call_id` of a queued request removes only that
    one.

## Expected outcome
- When an agent cancels a permission request, its float closes (or it
  leaves the queue), and the next request shows. The header's waiting
  state and the hidden-float badge clear as on an answer.
- The agent gets one answer per request: `-32800` for a cancelled one.
- No `Unknown notification method: $/cancel_request` notice.
- The tool call block's end comes from the agent's own update. The plugin
  adds no rejection line.

## Non-goals
- Cancelling other request kinds (`fs/*`): they are answered at once.
- The run clock of a cancelled request: it stays waiting (no time) until
  the agent's final update ends it. A request settled in another client
  of the same agent, whose tool then runs, gets no run time. Not observed.
- A queued request that `remove_request_by_tool_call_id` drops when its
  call fails is not answered, as today. Its `_permission_requests` entry
  stays until the next `_connect`.
- `BUG-unknown-jsonrpc-method-handling.md`'s dispatch split. This plan
  adds one branch to the current `_handle_notification`. The split moves
  it to the notification side.

## Open questions
