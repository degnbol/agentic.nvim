# Skip the attention bell on auto-approved permission requests

## Problem

When a `session/request_permission` arrives, the attention bell rings (if the
chat window is unfocused) *before* the client-side auto-approval checks run. So
a fully auto-approvable request — compound Bash command, read-only tool, cached
allow, trust-scope edit — still dings the bell even though no user input is
needed.

## Root cause

In `SessionManager:_on_request_permission` (`lua/agentic/session_manager.lua`):

- `session_manager.lua:988-996` — a pcall fires `_notify_attention("[?]", true)`
  and the `on_permission_request` hook **unconditionally**.
- `session_manager.lua:1006` — `add_request` runs *after*, and only then does
  `_try_auto_approve` (`ui/permission_manager.lua:650`) get a chance to
  short-circuit.

The notification is sequenced before the decision that would make it
unnecessary. `_notify_attention` rings the bell whenever the chat is unfocused
(`session_manager.lua:120-124`).

## Fix

Reorder so `add_request` runs first and reports whether an interactive prompt
was actually queued, then gate the notification + hook on that result.

### 1. `add_request` returns whether it queued an interactive prompt

`ui/permission_manager.lua:642-660`. Currently returns nothing. Change to
return a boolean — `true` only when the request entered the interactive queue
(user must act), `false` when auto-resolved or invalid:

```lua
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        return false
    end

    if self:_try_auto_approve(request, callback) then
        return false
    end

    local toolCallId = request.toolCall.toolCallId
    table.insert(self.queue, { toolCallId, request, callback })

    if not self.current_request then
        self:_process_next()
    end
    return true
end
```

`_try_auto_approve` already returns `true` on any auto-resolve (approve or
reject) via `auto_approve`/`auto_reject`, so no change there.

### 2. Reorder `_on_request_permission` to notify only when prompted

`session_manager.lua:984-1006`. Move `add_request` ahead of the notify/hook
block and gate on its return:

```lua
-- add_request must run regardless: if it never runs, the ACP permission
-- callback is lost and the provider waits forever, locking the session.
-- It also resolves auto-approvals synchronously and reports whether an
-- interactive prompt was queued — only then do we ring the bell / fire the
-- hook, so auto-approved requests stay silent.
local prompted = self.permission_manager:add_request(request, wrapped_callback)

if prompted then
    -- Notifications and hooks are non-essential UI; a throw here must not
    -- escape (add_request has already run, so the callback is safe).
    local ok, err = pcall(function()
        self:_notify_attention("[?]", true)
        P.invoke_hook("on_permission_request", {
            session_id = self.session_id,
            tab_page_id = self.tab_page_id,
            tool_call_id = request.toolCall.toolCallId,
        })
    end)
    if not ok then
        Logger.notify(
            "Error setting up permission UI: " .. tostring(err),
            vim.log.levels.WARN
        )
    end
end
```

The existing "must not prevent add_request" comment (`session_manager.lua:984`)
is now satisfied structurally — `add_request` runs first and unconditionally —
so rewrite it to explain the new ordering rather than the old pcall-before
rationale.

## Decision: gate the `on_permission_request` hook too?

Recommended: **yes** — gate both. `doc/agentic.txt:219` documents the hook as
"Fires on tool permission prompt", and `:245` documents the bell as firing on
"permission request". Auto-approved requests produce no prompt, so suppressing
both is consistent with the documented "prompt" semantics and keeps the bell
and hook aligned (they share the same attention-UI block today).

Alternative if a hook consumer needs to observe *every* request including
auto-approved ones: keep the hook firing unconditionally before `add_request`
and gate only `_notify_attention`. This is messier (two separate sites) and
contradicts the "prompt" wording. Only take it if a real consumer needs it —
none exists in-repo (`on_permission_request` is referenced only by config
defaults, docs, and a test that calls the hook directly).

## Edge cases

- **Invalid request** (no `toolCallId`): returns `false` → no bell. Correct —
  no prompt is shown and the callback is already lost; ringing would mislead.
- **Queued behind an in-flight prompt**: `add_request` still returns `true`
  (it entered the queue and needs user action eventually), so the bell rings.
  Matches today's "ring for every pending request" behaviour.
- **Hidden chat window** (float can't render, see
  `acp/AGENTS.md` § "Hidden chat"): `add_request` still queues and returns
  `true`. `_notify_attention` with `skip_badge=true` only rings when unfocused,
  which is the right signal regardless of float visibility. No change.
- **Synchronous callback during auto-approve**: `_try_auto_approve` →
  `auto_approve` invokes `wrapped_callback` synchronously inside `add_request`.
  That already happens today (just after the notify); reordering runs it just
  before. `wrapped_callback`'s `status_animation:start` / `_show_diff_in_buffer`
  paths are unaffected by ordering.

## Tests

`lua/agentic/session_manager.test.lua` has bell tests only for response-complete
(`:881-891`) and a hook test that calls the hook directly (`:946-967`) — neither
drives `_on_request_permission`. Add coverage:

1. **No bell on auto-approved request** — stub `permission_manager.add_request`
   to return `false`, drive `_on_request_permission`, assert `bell_stub` not
   called and the hook not fired.
2. **Bell on interactive request** — stub `add_request` to return `true`,
   assert `bell_stub` called once (chat unfocused) and hook fired.

Also add a `permission_manager` unit test asserting `add_request` returns
`false` when `_try_auto_approve` short-circuits and `true` when it queues.

The existing direct-hook test (`:946`) keeps passing — it doesn't go through
`_on_request_permission`.

## Docs

- `doc/agentic.txt:245` — tighten "permission request" to make clear the bell
  fires only on an interactive prompt, not on auto-approved requests (e.g.
  "...and on permission prompts that require a response").
- `doc/agentic.txt:219` — the hook line already says "permission prompt"; no
  change needed if the hook is gated.
- `CLAUDE.md:424` ("Attention notifications fire on two events") — note that the
  permission-request bell fires only when an interactive prompt is shown, after
  client-side auto-approval has been ruled out.

## Validation

`make validate` after the Lua changes (luals + selene + tests). Read the failure
log with `tail`/`rg`, never the Read tool.
