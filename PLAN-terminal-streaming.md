# Plan: ACP Terminal Streaming for Execute Tool Calls

**Goal:** Show execute tool call output streaming in real-time instead of waiting
for the command to finish.

**Status:** Not started

## Background

Currently, execute tool calls display output only after the command completes.
The provider runs the command internally, buffers all stdout, then sends the
complete body in a `tool_call_update` notification.

The ACP spec defines a [Terminals protocol](https://agentclientprotocol.com/protocol/terminals.md)
that inverts this: the provider asks the **client** to spawn the command, giving
the client direct subprocess access and real-time stdout. The provider polls for
output via `terminal/output`. Any ACP provider that checks `terminal = true` in
client capabilities can use this — it's not Claude-specific.

## Current architecture (relevant parts)

- `acp_client.lua:77` declares `terminal = false` in capabilities
- `_handle_notification` dispatches incoming JSON-RPC by method name
- `terminal/*` methods are **requests** (have `id`, expect a response), not
  notifications — they arrive with both `method` and `id` fields
- `_on_message` currently routes `method + id` messages to
  `_handle_notification` (which also handles `request_permission` this way)
- `MessageWriter:update_tool_call_block()` already supports incremental body
  updates — new body content is appended with `---` dividers (lines 699-709)
- `MessageWriter:write_message_chunk()` streams text incrementally for
  `agent_message_chunk` — the append-to-buffer pattern already works
- Tool call blocks are position-tracked via range extmarks in `NS_TOOL_BLOCKS`

## ACP terminal protocol summary

Five JSON-RPC **request** methods (all require `sessionId`):

| Method | Purpose |
|---|---|
| `terminal/create` | Spawn command, return `terminalId` |
| `terminal/output` | Return current accumulated output + truncation + exit status |
| `terminal/wait_for_exit` | Block until exit, return exit code/signal |
| `terminal/kill` | Send kill signal to process |
| `terminal/release` | Kill + deallocate all resources |

Tool calls reference terminals via content: `[{type: "terminal", terminalId: "..."}]`.

## Implementation plan

### Phase 1: Terminal manager (subprocess lifecycle)

Create `lua/agentic/acp/terminal_manager.lua`:

- Track active terminals: `terminals[terminalId] = { process, output_buf, exit_status, ... }`
- `create(params)` — spawn via `vim.fn.jobstart()` (not `vim.system()` — we need
  `on_stdout`/`on_stderr` callbacks for incremental output, and `jobstart` doesn't
  yield to the event loop like `vim.system():wait()` would inside a handler).
  Return `terminalId` (generate UUID or counter-based ID).
- `get_output(terminalId)` — return accumulated output string, truncation flag,
  exit status if finished. Respect `outputByteLimit` from create params.
- `wait_for_exit(terminalId, callback)` — if already exited return immediately,
  otherwise register callback for process exit event
- `kill(terminalId)` — send SIGTERM via `vim.fn.jobstop()`
- `release(terminalId)` — kill if running, clear output buffer, remove from tracking

Output accumulation: append stdout/stderr chunks to a string buffer (or table of
lines). Track byte count for `outputByteLimit` truncation.

### Phase 2: Request dispatch in ACPClient

`_handle_notification` already handles request-like messages (e.g.
`request_permission` has an `id` and expects a response via `__send_result`).
Add `terminal/*` methods to the same dispatch:

```lua
elseif method == "terminal/create" then
    self:__handle_terminal_create(message_id, params)
elseif method == "terminal/output" then
    self:__handle_terminal_output(message_id, params)
elseif method == "terminal/wait_for_exit" then
    self:__handle_terminal_wait(message_id, params)
elseif method == "terminal/kill" then
    self:__handle_terminal_kill(message_id, params)
elseif method == "terminal/release" then
    self:__handle_terminal_release(message_id, params)
```

Each handler: validate params, call terminal manager, send result via
`__send_result(message_id, result)`.

`terminal/wait_for_exit` is the only async one — it may need to defer the
response until the process exits (register a callback with the terminal manager
that calls `__send_result` when the process finishes).

### Phase 3: Enable capability

Set `terminal = true` in `acp_client.lua` capabilities. This tells providers
they can use `terminal/create` instead of running commands internally.

**Risk:** Providers may start using terminals for ALL execute calls immediately.
If phase 4 (live rendering) isn't ready, output would still appear but only when
the provider polls `terminal/output` and sends a `tool_call_update` referencing
it. The output would be visible in the tool call block but not streamed — same
UX as today. So phases 1-3 are safe to ship without phase 4.

### Phase 4: Live output rendering in tool call blocks

This is the UX improvement. When a tool call block references a terminal:

1. **Detect terminal content** — in `MessageWriter`, when processing a tool call
   whose content includes `{type: "terminal", terminalId: "..."}`, register a
   live output subscription instead of treating body as static.

2. **Incremental append** — the terminal manager's `on_stdout` callback notifies
   the MessageWriter (or a new component) that new lines are available. The
   handler appends lines to the tool call block's body region using
   `nvim_buf_set_lines` at the end of the block (before the footer line),
   updating the range extmark's `end_row`.

   This is analogous to `write_message_chunk` which appends at the buffer end,
   but scoped to a specific tool call block's extmark range. The existing
   `_with_modifiable_and_notify_change` wrapper handles the modifiable toggle.

3. **Throttle** — stdout can be very fast. Batch line appends on a timer
   (e.g. 50-100ms) to avoid flooding the buffer with individual `set_lines`
   calls. Accumulate lines between ticks, flush in one `set_lines` call.

4. **ANSI processing** — run `Ansi.process_lines()` on each batch before
   appending, same as current execute body handling.

5. **Fold threshold** — once output exceeds `execute_max_lines`, insert fold
   markers around the body (same as current static rendering). The fold starts
   closed, but new lines continue appending inside the fold region. Users can
   `zo` to watch live if they want.

6. **On exit** — when the process finishes, do a final flush, update the tool
   call status to the terminal exit status, stop the timer. The block becomes
   static (same as current completed execute blocks).

### Phase 5: Cleanup and edge cases

- **Session cancel (`<C-c>`)** — must `release` all terminals for that session.
  Wire into `SessionManager`'s cancel flow.
- **Tabpage close** — release terminals owned by that session. Wire into
  `SessionRegistry` cleanup.
- **Multiple terminals per session** — the manager supports this naturally (keyed
  by `terminalId`), but verify concurrent output rendering doesn't conflict.
- **Provider doesn't use terminals** — if a provider ignores the capability and
  keeps sending execute tool calls the old way, everything still works (the
  `tool_call_update` body path is unchanged).
- **`outputByteLimit` truncation** — must truncate at character boundary (UTF-8
  aware). Use `vim.str_byteindex` or similar.

## Open questions

- **Which providers actually use terminals?** Need to test with `claude-agent-acp`
  to confirm it sends `terminal/create` when the capability is advertised. If no
  provider uses it yet, phases 1-3 are speculative infrastructure.
- **`cwd` and `env` handling** — `terminal/create` accepts `cwd` and `env`.
  Should we pass these through to `jobstart` directly, or apply any policy
  (e.g. restrict cwd to project root)?
- **Permission interaction** — does the provider still send `request_permission`
  before `terminal/create`, or does terminal creation bypass permissions? Need to
  check with a real provider.
- **Scroll behaviour** — when streaming output into a fold, should the view
  auto-scroll to show new lines if the user has the fold open? Probably not by
  default (avoid hijacking scroll position), but could be configurable.

## File changes summary

| File | Change |
|---|---|
| `lua/agentic/acp/terminal_manager.lua` | New — subprocess lifecycle |
| `lua/agentic/acp/acp_client.lua` | Add terminal dispatch + `terminal = true` |
| `lua/agentic/ui/message_writer.lua` | Live append for terminal-backed blocks |
| `lua/agentic/session_manager.lua` | Release terminals on cancel/cleanup |
| `lua/agentic/acp/AGENTS.md` | Document terminal protocol and flow |
| `tests/` | Terminal manager unit tests, integration tests |
