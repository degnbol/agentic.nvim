# Plan: gemini permission requests through the base handler
Status: spec

## Relevant files
- `lua/agentic/acp/acp_client.lua` — `__handle_request_permission`,
  `__root_session`, `__send_result`, `_handle_notification` (the only
  dispatcher of `session/request_permission`)
- `lua/agentic/acp/adapters/gemini_acp_adapter.lua` —
  `__handle_request_permission`, `__handle_tool_call`
- `lua/agentic/ui/permission_manager.lua` — the callers that pass `nil`
  for a request resolved unanswered: `cancel_requests`,
  `reject_and_cancel_remaining`, `remove_request_by_tool_call_id` (via
  `_complete_request(nil)`); the option-kind loop in `_complete_request`
- `lua/agentic/session_manager.lua` — `_on_request_permission` (the
  subscriber for both handlers, unchanged)
- New `lua/agentic/acp/permission_options.lua` and its test
- Tests: `lua/agentic/acp/adapters/gemini_acp_adapter.test.lua` (today one
  `ignores_output` case), `lua/agentic/acp/acp_client.test.lua` ("child
  sessions": `make_client`, `spawn`, `recording_handlers`)
- Skills: `provider-system` § "Adapter override points", § "Permission
  optionId is opaque"; `permissions` § "Permission response keys"

## Background
`GeminiACPAdapter:__handle_request_permission` is a copy of
`ACPClient:__handle_request_permission` with two additions: a synthetic
`tool_call` before the prompt (gemini sends the edit diff and the command
only in the permission request), and a synthetic `failed` update after a
reject (gemini sends none). The base carries the comment "Every change to
this block MUST be reflected in Gemini's ACP Adapter". The copy drifted:

1. **Nil optionId.** The base sends `{ outcome = "cancelled" }` when the
   callback gets `nil`. Gemini's copy always sends `{ outcome = "selected",
   optionId = option_id }`, so a request resolved unanswered sends no
   `optionId`, which the ACP schema does not allow
   (`RequestPermissionOutcome`: `selected` requires `optionId`). `nil`
   comes from `cancel_requests` (stop, `/new`, session end), from
   `reject_and_cancel_remaining` (`Lx`) and from
   `remove_request_by_tool_call_id`. Gemini then never hears that the
   request was cancelled. This happens on every cancel of a pending gemini
   prompt.
2. **No root lookup.** The copy reads `self.subscribers[session_id]`; the
   base reads `self.subscribers[self:__root_session(session_id)]`. A request
   from a child session finds no subscriber and is cancelled without a
   prompt. Latent: the client advertises `subagents` for every provider, but
   nothing in this repo shows that gemini-cli opens child sessions.
3. The copy's reject detection compares the opaque `optionId` with
   `"cancel"`. The base and `PermissionManager` read an option's `kind`
   (`provider-system` § "Permission optionId is opaque"). gemini-cli's
   reject option has id `cancel` and kind `reject_once`, so reading the
   kind keeps today's behaviour.

The base handler with a resolution hook removes the copy: the gemini
override only adds what gemini needs before and after. The alternative,
marking every rejected call `failed` on the client for all providers,
would put one provider's gap into shared code; the provider's own adapter
is where that belongs.

The kind of the option an id names is looked up by hand in
`_complete_request`. The gemini hook needs the same lookup, so it becomes
one function in the ACP layer (an adapter must not require a `ui/` module).

## Changes
### New `lua/agentic/acp/permission_options.lua`
```lua
--- The kind of the permission option `option_id` names, normalised.
--- @param options agentic.acp.PermissionOption[]
--- @param option_id string|nil
--- @return string kind `AcpKind.normalise` of the option's kind; "" when no option has the id
function M.option_kind(options, option_id)
```
`PermissionManager:_complete_request` uses it in place of its loop.

### `acp_client.lua`
- New protected hook, called inside the callback of
  `__handle_request_permission` after `__send_result`, in both the
  `selected` and the `cancelled` branch:
  ```lua
  --- Called with the option a permission request was resolved with, after the
  --- result is sent. Default: no-op.
  --- @protected
  --- @param request agentic.acp.RequestPermission
  --- @param option_id string|nil Nil when the request was cancelled
  function ACPClient:__on_permission_resolved(request, option_id) end
  ```
  After the send, so that an error in the hook cannot keep the provider
  waiting: `_complete_request` calls the callback without `pcall`.
- Delete the "MUST be reflected in Gemini's ACP Adapter" comment.

### `gemini_acp_adapter.lua`
- `__handle_request_permission(message_id, request)`: send the synthetic
  `tool_call` for `edit`/`execute` (guard `request.toolCall and
  request.toolCall.kind`, so a malformed request reaches the base's
  `Invalid request_permission` error), then call
  `ACPClient.__handle_request_permission(self, message_id, request)`.
  Delete the subscriber lookup, the `vim.schedule`/`pcall` block and its
  error handler.
- New override `__on_permission_resolved(request, option_id)`: when
  `vim.startswith(PermissionOptions.option_kind(request.options,
  option_id), "reject_")`, call
  `self:__handle_tool_call_update(request.sessionId, { sessionUpdate =
  "tool_call_update", toolCallId = request.toolCall.toolCallId, status =
  "failed" })`. A `nil` option_id gives `""` and sends nothing. Today
  nothing is sent then either; the turn-end sweep ends the call
  (`provider-system` § "Tool call lifecycle").

### Tests
Write these first.

`permission_options.test.lua`: a kind is normalised; an unknown id and a
`nil` id give `""`.

`gemini_acp_adapter.test.lua`. The client is built as the "child
sessions" `make_client` in `acp_client.test.lua` builds it (`subscribers`,
`_children`, `_loading_sessions`, `_session_roots`, `_tool_call_kinds`),
with `__index = GeminiACPAdapter`, a capturing `__send_result`,
`recording_handlers()` and `Deferred.capture()`. Options are shaped as
gemini sends them: `{ optionId = "proceed_once", kind = "allow_once" }`,
`{ optionId = "cancel", kind = "reject_once" }`. Cases:
- a callback with `nil` sends `{ outcome = "cancelled" }` and, after
  draining, no `tool_call_update`;
- the `cancel` option sends `selected` with `optionId = "cancel"`; after
  draining, the subscriber got one `failed` `tool_call_update` for the
  call;
- a reject option with id `deny`, kind `reject_once`, also gives the
  `failed` update (detection reads the kind, not the id);
- the allow option sends `selected` and no update;
- an `edit` request delivers the synthetic `tool_call` before
  `on_request_permission`;
- a child session's request reaches the root's subscriber.

`acp_client.test.lua`: a callback with `nil` sends `{ outcome =
"cancelled" }` (no such base case exists today); the hook gets the
callback's option id, `nil` included, after the result is sent.

## Expected outcome
- Cancelling a pending gemini prompt sends `cancelled`, not `selected` with
  no optionId.
- A gemini child session's permission request prompts in the root chat.
- A gemini reject still ends the call `failed` in the chat.
- One permission handler for every provider, and one option-kind lookup.

## Non-goals
- The synthetic `tool_call` for `edit`/`execute` (behaviour unchanged). It
  calls `__handle_tool_call` directly, so it skips `_apply_tool_call_kind`
  and the unknown-kind warning; unchanged.
- The inverse lookup (option id of a kind): `find_option_id` in
  `permission_manager.lua` and the loop in `SessionManager`'s
  `wrapped_callback`.
- Other gemini adapter code (tool-call builders:
  `REFACTOR-acp-tool-call-builders.md`).
- Checking whether gemini-cli opens child sessions.

## Open questions
None.
