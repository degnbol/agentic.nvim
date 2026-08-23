# Error classification: dispatch on structured `errorKind`, not message text

## Problem

The chat renders a raw, unclassified error for the org spend cap:

```
### Error
Internal error: You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit
```

No reset countdown, no auto-continue — behaviour that used to work for the
subscription "out of extra usage" limit.

### Root cause: the input changed, the receiving code did not

The plugin classifies errors by **pattern-matching `err.message` text**
(`message_writer.lua:428` `format_error_lines`). The usage-limit branch keys on
a `resets <time> (<tz>)` substring (`message_writer.lua:470-474`). That regex
was written for the subscription message
`"You're out of extra usage · resets 5pm (Europe/London)"`.

The provider stack updated underneath us:

- `@agentclientprotocol/claude-agent-acp` **0.29.0 → 0.58.1**
- `@anthropic-ai/claude-agent-sdk` **0.2.111 → 0.3.205**
  (last-verified versions recorded in `.claude/skills/issues/references/chunk-flush.md`)

Two things changed in what we're fed:

1. The org spend cap is a **different error class** than the subscription
   window. Its message carries no `resets <time> (<tz>)` clause, so the regex
   misses and `format_error_lines` falls through to the raw fallback
   (`error_type = nil`) — no classification, no recovery.

2. The bridge now attaches a **structured error kind** to the JSON-RPC error's
   `data` payload, explicitly so clients stop parsing message text.
   `acp-agent.js:3207`:

   > The `errorKind` field is a convention for ACP clients to dispatch on
   > without having to pattern-match the human-readable message text. Clients
   > that don't understand it fall back to the existing message-based
   > rendering.

   Populated via `RequestError.internalError(errorKindData(lastAssistantError), message.result)`
   (`acp-agent.js:1389`; `errorKindData` at `:3203-3207`;
   `lastAssistantError = message.error` at `:1623`, reset to `undefined` at
   `:690`), where `lastAssistantError` is the SDK's `SDKAssistantMessageError`
   enum (defined `sdk.d.ts:2822`):

   ```
   authentication_failed | oauth_org_not_allowed | billing_error | rate_limit
   | overloaded | invalid_request | model_not_found | server_error | unknown
   | max_output_tokens
   ```

   The spend cap is `errorKind = "billing_error"`.

`err.data` already reaches us — `ACPError` types it (`acp_client.lua:1377`
`data? any`) and the response callback forwards the raw JSON-RPC error
(`acp_client.lua:418` `callback(message.result, message.error)`). We simply
never read it.

## General principle

**Classify errors from the bridge's structured `errorKind` field; keep text
heuristics only as a fallback for errors/bridges that lack it.**

Message text is a display artefact, not an API contract — any upstream wording
change silently breaks a regex keyed on it. `billing_error` is just the
instance that bit us; the same fragility applies to every text-matched class
(auth, rate limit, overload). Keying on the enum immunises all of them at once
and is what the bridge author explicitly asks clients to do.

A second structural change follows from the same shift: **classification and
reset-time are now separate structured signals.** The old regex bundled them
(both scraped from one string). Now:

- Class → `err.data.errorKind`.
- Reset epoch (rate limits only) → `self._budget.resetsAt`, already tracked
  from `rate_limit_event` / `_claude/rateLimit` meta
  (`session_manager.lua:587`, `_budget_status` at `1443`).
- `billing_error` has **no reset epoch** — a spend cap clears when an admin
  raises it or credits are purchased, not on a timer. Correct behaviour is a
  hint, no auto-continue.

## Current code map

- `message_writer.lua:428` `format_error_lines(err)` — reads only `err.message`.
  Embedded-JSON path (Anthropic `error.type`: `overloaded_error`,
  `rate_limit_error`, `authentication_error`), then usage-limit regex, then raw
  fallback. Returns `(lines, error_type, reset_epoch)`.
- `message_writer.lua:389` `error_hints` — keyed by Anthropic `error.type`
  (`overloaded_error`, `rate_limit_error`).
- `message_writer.lua:399` `parse_reset_time` — GNU `date` text → epoch.
- `session_manager.lua:1847` (send_prompt callback) — **the only live dispatch
  site.** `authentication_error → offer_reauth`; `usage_limit → respawn +
  (reset_epoch → offer_auto_continue)`.
- `session_manager.lua:934` `on_error` handler — **dead code.** Defined in the
  handlers table but `.on_error(` is invoked nowhere in the repo (verified by
  fixed-string grep). Vestigial duplicate of the dispatch logic.

Two error vocabularies are in play and must be reconciled: the SDK `errorKind`
enum vs the Anthropic `error.type` strings the embedded-JSON path already
produces.

## Plan

Split into two phases (per plan-review, which flagged bundling the fix with the
riskier reset-sourcing refactor). **Phase A** is the self-contained fix + the
general errorKind-first mechanism; it does not touch the reset pipeline and
keeps `format_error_lines`'s existing 3-value signature. **Phase B** is the
deferred, decision-gated reset-epoch re-sourcing.

### Phase A — errorKind-first classification (the fix)

#### A1. errorKind → internal class map (conservative)

A `local` lookup in `message_writer.lua` beside `error_hints`, populated only
with kinds whose recovery semantics we're confident about now. Everything else
falls through to the existing text heuristics (no regression).

| errorKind | internal class | recovery |
|---|---|---|
| `authentication_failed`, `oauth_org_not_allowed` | `authentication_error` | offer_reauth (existing, safe) |
| `billing_error` | `billing_error` | none — hint only |
| everything else | *(not mapped in A)* | text fallback → existing behaviour |

`rate_limit` is **deliberately not mapped in Phase A** — the subscription
limit still classifies via the existing text path and shows its reset through
`_budget`. Mapping it here would reopen the `rate_limit` vs `rate_limit_error`
question (below) and change respawn/auto-continue behaviour. Deferred to B.

#### A2. `format_error_lines` prefers `errorKind`, signature unchanged

Order inside `format_error_lines(err)`:

1. If `err.data` is a table with a mapped `errorKind` → set class from the map,
   build display lines from `err.message` **with the `Internal error: ` /
   `API Error: NNN` wrapper prefix stripped** (the embedded-JSON path already
   strips its prefix; match that), attach hint. Return `(lines, class, nil)`.
2. Else the existing embedded-JSON path (unchanged).
3. Else the existing usage-limit regex (unchanged — still returns a
   text-scraped `reset_epoch`).
4. Else the existing raw fallback.

Signature stays `(lines, class, reset_epoch)`. Phase A only ever returns
`reset_epoch = nil` from the new branch (billing has no reset); the text paths
keep returning it as today. `write_error_message` (`:495`) and its live caller
(`:1849`) are unchanged — no arity change, Blocking §2 does not apply to A.

#### A3. `error_hints`: add `billing_error`

Actionable, factual (no invented reset semantics), e.g.:

```
billing_error = "Organisation spend limit reached. Raise the cap in the "
    .. "Anthropic Console, or run /usage-credits to request an increase.",
```

#### A4. Dispatch: handle `billing_error` as display-only

Send_prompt callback (`session_manager.lua:1847`): `billing_error` → no
`offer_reauth`, no `respawn`, no `offer_auto_continue` (hint already in the
body). Existing `authentication_error` / `usage_limit` branches unchanged.

#### A5. Remove the dead `on_error` handler

`session_manager.lua:934` is unreachable (verified: no `subscriber.on_error`
call anywhere; delivery is solely the send_prompt callback). Delete it, its
`ClientHandlers.on_error` alias/field (`acp_client.lua:1381,1394`), **and the
`on_error = function() end` stub in `acp_client.test.lua:262`** (else it becomes
an undefined-field under LuaLS).

#### A6. Tests (write first)

- `message_writer.test.lua` — `format_error_lines`:
  - `err.data.errorKind = "billing_error"` → class `billing_error`, body has the
    message with `Internal error: ` prefix stripped, hint present, `reset_epoch`
    nil.
  - `= "authentication_failed"` → class `authentication_error`.
  - unmapped errorKind (`server_error`) with a message → falls through to text,
    class per text path.
  - no `data`, embedded JSON present → existing classification unchanged.
  - no `data`, no JSON → raw fallback, class `nil`.
- `session_manager.test.lua` — dispatch: `billing_error` → no reauth, no
  respawn, no auto-continue.

#### A7. Docs

- Update `format_error_lines` / `write_error_message` docstrings: errorKind-first
  classification, text as fallback. Note the retained 3-value return.
- One line in the `provider-system` project skill recording that classification
  keys on `err.data.errorKind`. No `doc/agentic.txt` change (internal).

### Phase B — reset-epoch from `_budget` (deferred, decision-gated)

Only worth doing once the two decisions below are made. Nothing in the reported
bug requires it.

- **B1.** Map `rate_limit` (errorKind) → `usage_limit` in the A1 table, and
  source the reset epoch at the dispatch site from `self._budget.resetsAt`
  (normalised for `>1e12` ms as `_budget_status:1448` does), **preferring it
  over** the text-scraped `reset_epoch` that `format_error_lines` still returns.
  Keep the 3-value signature so the text-scraped epoch remains a fallback when
  `_budget` is absent/stale (resolves Blocking §2's conflict — do *not* drop to
  a 2-value return).
- **B2.** Only call `offer_auto_continue` when a reset epoch is known from
  either source.

Open decisions for B:

1. **`rate_limit` vs `rate_limit_error`.** The SDK's single `rate_limit`
   covers both a transient 429 and a subscription-window limit; the bridge
   can't distinguish them. Mapping to `usage_limit` triggers
   `respawn_after_usage_limit` + auto-continue unconditionally. Decide whether a
   transient 429 should respawn+auto-continue, or only the window case. If they
   must differ, `errorKind` alone is insufficient and `_budget`/text inspection
   is still required.
2. **Is `_budget.resetsAt` populated at `rate_limit` error time?** `_budget`
   updates from `rate_limit_event`/usage_update meta; ordering vs the error is
   not guaranteed. Confirm before relying on it as primary.

## Risks / open questions

1. **Is `errorKind` present for a billing error in practice?** Type flow
   supports it (`acp-agent.js:1623` → `:1389`), but `errorKindData` returns
   `undefined` unless a top-level assistant frame with `.error` arrived before
   the result — order-dependent. I have not captured a live `err.data` for the
   spend-cap case (debug log contaminated with this session's own tool output).
   Log a clean `err.data` capture before trusting the errorKind path as primary.
   The text fallback stays regardless; A5's deletion is scoped to the dead
   handler only, never the text classification fallback.
2. **Other `errorKind` values** (`invalid_request`, `model_not_found`,
   `server_error`, `max_output_tokens`, `unknown`) — left unmapped → text/raw
   fallback. Add hints only where actionable, later. Don't over-map.
3. **errorKind vs embedded `error.type` disagree** — errorKind is authoritative
   (checked first); low risk, noted for completeness.
