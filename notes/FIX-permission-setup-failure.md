# Plan: Resolve a permission request whose prompt setup fails
Status: reviewed spec

## Relevant files
- `lua/agentic/ui/permission_manager.lua` — `add_request`, `_process_next`, `_apply_unapproved_highlight`, `_complete_request`, `cancel_requests`, `reject_and_cancel_remaining`, `_release_request`
- `lua/agentic/ui/permission_manager.test.lua` — `open_stub` (`:48`), `describe("cancel_requests")`
- `lua/agentic/ui/permission_highlight.lua` — module docstring: pure UI, the prompt still fires
- `lua/agentic/acp/acp_client.lua` — `__handle_request_permission` (pcall around `on_request_permission`)
- `lua/agentic/session_manager.lua` — `_on_request_permission` (`if prompted then` block)
- Skills: `permissions`, `session-lifecycle`

## Background
`_process_next` opens the float, then applies the unapproved highlight, then
sets `current_request`, takes the hold and binds the option keys. If a step
after `permission_float:open` throws, the float stays open with no
`current_request` and no keys:
- The option keys fall through to other maps. `<localLeader>y` sends the
  `keymaps.prompts` text ("Go ahead.").
- `cancel_requests`, `reject_and_cancel_remaining` and `_complete_request`
  close the float only when `current_request` is set, so nothing closes it.

The throw reaches two different callers:
1. From `add_request` (first request). The pcall in
   `ACPClient:__handle_request_permission` catches it and sends `cancelled`.
   The provider gets an answer, but the float stays.
2. From `_complete_request` (the next queued request, after the user answers
   one). No pcall catches it. The request is already off the queue and never
   gets an answer, so the provider waits forever.

A fix in `acp_client` cannot reach caller 2, and the wrong state belongs to
`PermissionManager`. So `_process_next` resolves its own request when setup
fails.

The highlight is a special case. `PermissionHighlight` documents that it is
pure UI and that the prompt still fires when it highlights nothing. So a
highlight throw is reported and the prompt shows without the wash. Only a
throw in the other setup steps cancels the request.

Seen trigger: the `xargs` highlight range overflow.

Facts the design depends on:
- Nothing reads `current_request` during `permission_float:open`.
  `refresh_float` runs only from the `_watch_layout` autocmd, through
  `vim.schedule`, and that autocmd is made later in setup. `open` → `set_anchor`
  → `place` makes only float-internal autocmds. Outside this file, only tests
  read `.current_request`.
- `MessageWriter:release_hold` is a no-op without a hold, and
  `permission_float:close` is safe when closed. So `_release_request` is safe
  before `hold_tool_call` ran. `proxy_held` starts `false`.
- `_release_request` calls `request.writer:release_hold()` without a nil
  check. So `writer` must be resolved before `current_request` is built.
- `callback(nil)` → `wrapped_callback` → ACP `__send_result` and
  `__on_permission_resolved`. Nothing in that chain calls back into
  `PermissionManager` synchronously (the Gemini override acts only on
  `reject_*`).

## Changes
`lua/agentic/ui/permission_manager.lua`:
- New `PermissionManager:_resolve_current(option_id)`. Docstring: "Close the
  current prompt and answer its request with `option_id` (nil to cancel)."
  Body: close the float, clear the highlight, `_release_request`, pcall the
  callback (on error `Logger.notify`, as in `cancel_requests` now), set
  `current_request = nil`. Each caller records its cause first.
  `_complete_request`, `cancel_requests` and `reject_and_cancel_remaining` use
  it for the current request. This also protects the callback in
  `_complete_request`. Today, a callback that throws there leaves
  `current_request` set with the float closed.
- `_process_next`:
  - Pop the item, sort the options and resolve `writer` first. A throw in
    `_writer` is out of scope (see Non-goals).
  - Build `self.current_request` with `option_mapping = nil` before
    `permission_float:open`.
  - Run the setup steps in one `xpcall(fn, debug.traceback)`: `open` and the
    assignment of `option_mapping`, highlight, `hold_tool_call`,
    `_sync_proxy_hold`, `_watch_layout`, `_sync_keymaps`, `_set_hidden`.
  - On failure: `Logger.notify("Permission prompt failed, cancelling:\n" .. trace, ERROR)`,
    record `prompt-cancel`, `_resolve_current(nil)`, then `_process_next()`.
    This order makes a callback that calls `add_request` queue its request
    and not open a second float. The recursion stops when the queue is empty.
- `_apply_unapproved_highlight`: call `PermissionHighlight.apply` in
  `xpcall(…, debug.traceback)`. On error, `Logger.notify` the trace and
  return. The prompt shows without a wash.
- `add_request`: return whether the request is still pending after
  `_process_next`. That is true when `current_request.request` is the request
  or the request is still in `self.queue`. Then `SessionManager` does not
  start the wait clock or fire `on_permission_request` for a request that
  was already cancelled. This matches the docstring ("true only when an
  interactive prompt was queued").

`lua/agentic/ui/permission_manager.test.lua`, new `describe("setup failure")`
next to `describe("cancel_requests")`:
- Make `open_stub` throw for the first request. Then:
  - `add_request` does not throw and returns `false`.
  - The callback gets nil, and `prompt-cancel` is recorded.
  - `current_request` is nil, and `writer._held_tool_call_id` is nil.
  - `pm._layout_autocmd` is nil, and `<localLeader>1` is not mapped on the
    buffer.
- Make `_sync_keymaps` throw, so the failure comes after `open` succeeded. The
  float is closed and the same assertions hold.
- Queue two requests and answer the first. Make setup throw for the second.
  The second callback gets nil, and a third queued request opens normally.
- Make `PermissionHighlight.apply` throw for an execute request with a
  tracker and `highlight_unapproved` on. The prompt opens, its keys are bound,
  the request stays pending, and `add_request` returns `true`.

`acp_client.lua` and `session_manager.lua` do not change.

## Expected outcome
- A highlight throw shows an error notification with a traceback. The prompt
  still opens and works.
- Any other setup throw shows an error notification with a traceback, and the
  provider gets `cancelled` for that request. In caller 1,
  `__on_permission_resolved` now also runs (with nil, so it does nothing).
- No float stays open without keys, and the option keys never fall through
  while a prompt is shown.
- A queued request is always answered, also when its setup throws.

## Non-goals
- The `xargs` highlight range overflow itself.
- A throw in `_writer` or `_sort_permission_options`, or in the cleanup
  inside `_resolve_current` before the callback runs.
- Errors in `_try_auto_approve` or in `SessionManager:_on_request_permission`
  before `add_request`. The `acp_client` pcall already answers those, and
  they leave no UI behind.

## Open questions
None.
