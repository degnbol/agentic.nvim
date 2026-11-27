# Bug: unknown JSON-RPC method dispatch

## Background

`ACPClient:_handle_message` routes every inbound message with a `method` and no
`result`/`error` to `ACPClient:_handle_notification`. That function dispatches
five methods and calls `Logger.notify("Unknown notification method: …")` on
anything else.

Two defects sit in that one branch.

**Unknown requests get no reply at all.** `_handle_notification` is misnamed:
three of the five methods it dispatches are requests carrying an `id` —
`session/request_permission`, `fs/read_text_file`, `fs/write_text_file` — and
each answers via `__send_result` or `_send_error`. A request whose method falls
through gets a notice and no response, and the agent waits on it forever.

**Unknown notifications become popups, one per message.** The fallback
`Logger.notify` has no dedup, so a provider that sends an unhandled
notification repeatedly produces one notice per message.

The client-directed surface of claude-agent-acp 0.85.1:

| Kind | Methods |
| --- | --- |
| Notifications | `session/update`, `_auth/status_update`, `elicitation/complete`, `_claude/sdkMessage`, `$/cancel_request` |
| Requests | `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `elicitation/create` |
| Never sent by this bridge | all `terminal/*`, `mcp/*` |

`session/update` and `_auth/status_update` have handlers. `elicitation/create`
is gated behind `clientCapabilities.elicitation.form|url`,
`elicitation/complete` behind `elicitation.url`, and `_claude/sdkMessage`
behind a `_meta.claudeCode.emitRawSDKMessages` key the plugin never sets. None
is advertised (`ACPClient:new` `capabilities`), so no unanswerable request
reaches this bridge today. `$/cancel_request` is not gated: the ACP SDK sends
it when `session/request_permission` (or `elicitation/create`) aborts.
`FIX-cancel-request-handler.md` gives it a handler. The dispatch is provider-agnostic and five
other providers are configured, none of them audited — the fallback exists for
them as much as for the latent case here.

## Changes

Split the dispatch by the presence of `id`, nested inside the existing guard —
not replacing it, since every *response* also carries an `id`:

```
method and not result and not error → id present ? _handle_request : _handle_notification
id and (result or error)            → pending callback
otherwise                           → Logger.notify("Unknown message type: …")
```

`vim.json.decode` maps JSON `null` to `vim.NIL`, which is truthy in Lua. That
matters in the second branch: a `{"id":N,"result":null}` response reaches it
because it has no `method`, and `(message.result or message.error)` classifies
it as a response only because `vim.NIL` is truthy. The first branch's
`not result and not error` guards a malformed message carrying both, which
JSON-RPC does not produce.

- `ACPClient:_handle_request(message_id, method, params)` dispatches the three
  id-bearing methods and answers anything else with
  `self:_send_error(message_id, "Method not found: " .. method,
  self.ERROR_CODES.METHOD_NOT_FOUND)`.
- `ACPClient:_handle_notification(method, params)` dispatches `session/update`,
  `_auth/status_update` and `$/cancel_request`, and reports anything else. It loses its `message_id` parameter.
- Discriminate on `message.id ~= nil and message.id ~= vim.NIL`. `0` is the
  ordinary id, not an edge case — the bridge's counter starts there — and that
  test admits it. A bare truthiness test does not work: it would answer a
  notification spelled `"id": null` with a `-32601` addressed to `null`.
- `ERROR_CODES` gains `METHOD_NOT_FOUND = -32601`, with a comment marking it as
  the odd one out: every other entry is a vendor-range `-320xx` code, and this
  one is the JSON-RPC standard code for the condition — the same code the ACP
  SDK itself emits for an unknown method (`RequestError.methodNotFound`). The
  bridge does not key on it.
- `_send_error` and `__send_result` annotate `@param id number`, and the three
  existing handlers annotate `@param message_id number`. JSON-RPC ids may be
  strings, and this is the first path that echoes back an id the plugin did not
  mint. Widen all of them to `number|string`.

Two behaviour changes fall out of the split and should be expected rather than
discovered: a request method arriving *without* an id is now reported as
unknown instead of dispatched, and a notification method arriving *with* one is
answered `-32601`. Both mean the provider contradicted the protocol, and both
are better surfaced than silently mishandled.

### Reporting

Introduce the reporter here rather than depending on another change for it:
this is the first caller, and the unknown-kind warning in
`ACPClient:__handle_session_update` (gated on `AcpKind.PROTOCOL_KINDS`) already
hand-assembles the same kind of "please report" message.

```lua
--- Notify once per distinct summary that the provider sent something this
--- client cannot act on.
--- @protected
--- @param summary string
function ACPClient:__report_unsupported(summary)
```

Dedup lives inside it, on `self._reported` created at first use — per client
instance, so it dies with the subprocess and needs no teardown. It is not a
caller-side flag: every caller wants the same thing, and a kwarg toggle on a
low-level helper would be the wrong shape.

The summary is what dedup keys on, so it must carry the signal's *shape* and no
per-call values. Here that is the method name alone; a summary interpolating an
id or a session would degrade dedup to none.

On this bridge the rate is zero by construction: with `$/cancel_request`
handled, every remaining unhandled method is gated behind a capability the
plugin does not advertise. Dedup is insurance against the five unaudited
providers rather than a fix for known volume.

Unknown *requests* report on the same terms. The `-32601` frame goes out every
time regardless; only the notice is deduped.

`__report_unsupported` belongs on `ACPClient` rather than in a module of its
own: it carries no provider-specific knowledge, and it needs `self` for the
dedup table. Adapters inherit it.

`provider-system/SKILL.md` describes `ACPClient` as routing "notification vs
response"; it becomes a three-way split.

## Tests

`acp_client.test.lua` already drives `_handle_message` directly, including an
`id = 99` `session/request_permission`.

- An unknown id-bearing method: the transport receives an error frame carrying
  `-32601` and the same `id`.
- An unknown method with `id = 0`: same, rather than being taken for a
  notification.
- An unknown notification: one report, nothing sent.
- The same unknown notification twice: still one report. A *different* unknown
  method: a second report.
- `"id": null` decoded by `vim.json.decode` rather than hand-built, so the real
  sentinel is exercised: reported, nothing sent.
- A string id echoed back unchanged.
- `{ id = N, result = vim.NIL }`: still reaches the pending callback. The
  stakes rose with this change — a misclassification now writes to the wire.
- `session/update`, `_auth/status_update`, `$/cancel_request`,
  `fs/read_text_file` and `fs/write_text_file` still reach their handlers
  across the split.

## Expected outcome

An unimplemented request fails immediately with a code its caller understands
instead of hanging. An unimplemented notification is named once, so a provider
growing a capability is visible rather than silent.

## Non-goals

Implementing the extension methods themselves. This is the fallback for a
method no handler exists for, and it must stay after each new handler lands:
bridges add extension methods between releases.
