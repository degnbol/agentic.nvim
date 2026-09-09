# Show why a tool call was permitted

Status: **not designed.** Split out of `notes/PLAN-hooks_in_chat.md` — it shares a
data source with surfacing hook activity, but is a separate UI concern.

## Problem

When a tool call runs without prompting, nothing in the UI says *why*. The
possibilities are meaningfully different to the user:

- a deterministic client-side rule allowed it — and *which* rule (`read-only`,
  `safe-write`, a compound-Bash match, an allow-always cache entry, `/trust`
  scope)
- the SDK's own auto-allow resolved it
- under auto mode, the LLM classifier allowed it — which costs money and latency,
  and by construction means *no* deterministic rule matched

The last distinction is exclusive in both directions: a call allowed by the
classifier was not allowed by `/trust` or the built-in structured auto-allow, and
vice versa. So naming the mechanism is genuinely informative, not decoration.

## Shape

One line on the tool call. Short — the rule name, not a sentence.

The four client-side auto-approval mechanisms and the `/trust` safety properties
are documented in the `permissions` project skill; `PermissionManager`,
`PermissionRules` and `TrustSafety` already hold the verdict logic, so the
information exists in-process.

## Hard constraint: not inside the hook

The plugin's deterministic ladder runs as a `PreToolUse` hook
(`hooks/permission_hook.sh` → `permission_hook.lua`, see
`notes/PLAN-auto-mode-integration.md`). **Do not do the rendering there.** Two
reasons:

1. `permission_hook.lua:56-96` wraps the whole verdict computation in a single
   `pcall` that returns `""` (abstain) on any error. A render side-effect inside
   that scope turns a UI bug into a **silently changed permission decision** —
   fail-open, riding along with a display feature.
2. That script has already hung: all three `hook_cancelled` records in this
   project's transcript history are `hooks/permission_hook.sh` at 600 s. Adding
   synchronous UI work to it makes a hang more likely, and a hung permission hook
   blocks the tool call.

A hung UI outranks knowing which rule allowed a call. If the two ever conflict,
the hang concern wins.

So: store the verdict on the per-session `PermissionManager` and let the render
path read it, rather than pushing it from the hook.

## Open

- Where the line goes on the block (the tool-call footer already carries status).
- What to show when nothing matched and the SDK resolved it — the plugin has no
  visibility into the SDK's own rule set (see the `provider-system` skill § "No
  permission rule management via ACP").
- Whether classifier-allowed calls are worth flagging more prominently, given
  they cost money.
