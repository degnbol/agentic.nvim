# Usage-limit errors without a reset clause are not classified

## Symptom

A claude.ai subscription that hits its limit with extra usage blocked shows a
raw error, with no hint, no respawn, no reset gate and no auto-continue:

```
## Error

You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit
```

The text names why extra usage cannot cover the overflow (org spend cap). It
does not always name the limit that rejected the request. That limit can be a
subscription window, so the user sees "monthly spend limit" when the monthly
limit is not what was hit.

## Mechanism

1. **The CLI tags every subscription 429 as `rate_limit`.** In the bundled CLI
   (claude-agent-sdk 0.3.286), the 429 path builds the message from the
   rejected `rate_limit_info` (`Acn`) and returns it with
   `error: "rate_limit"`. The org-spend-cap text, the individual-spend-limit
   text and the plain window text all come from this one path.
2. **The CLI adds the reset clause only sometimes.** It appends
   `· your <limit> resets <time> (<tz>)` only when the rejection names a window
   (`five_hour`, `seven_day`, …) with a `resetsAt`, and an internal plan/model
   check passes. Otherwise the message has no reset time.
3. **The bridge forwards the kind unchanged.** claude-agent-acp 0.85.1 sends
   `RequestError.internalError({ errorKind: lastAssistantError }, message.result)`
   (`acp-agent.js:4326`, `errorKindData` at `:7477`).
4. **The plugin does not map `rate_limit`.** `error_kind_class`
   (`message_writer.lua:1503`) maps only `authentication_failed`,
   `oauth_org_not_allowed` and `billing_error`. For `rate_limit`,
   `format_error_lines` (`:1564`) falls through to the text path. The
   usage-limit regex (`:1641-1650`) needs `resets <time> (<tz>)`. A message
   without that clause reaches the raw fallback (`:1652`) and returns class
   `nil`.
5. **The dispatch site does nothing for class `nil`.** The `send_prompt`
   callback (`session_manager.lua:3741-3762`) acts only on
   `authentication_error` and `usage_limit`. `_usage_reset_epoch` stays unset,
   so the submit gate (`:3009`) does not hold queued prompts.

A message with the reset clause still works through the regex, for example
`You've hit your individual spend limit · … · your session limit resets 2:20pm (Europe/London)`.

## Evidence

- Session cache (`~/.cache/nvim/agentic/sessions/`), provider prose that
  repeats the error text:
  - 55 × `You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit`.
    No reset clause. All unclassified.
  - 14 × individual spend limit with `· your session limit resets <time>`,
    6 × `You've hit your session limit · resets <time>`,
    1 × `You've hit your limit · resets <time>`. All match the regex.
- CLI transcripts (`~/.claude/projects/**/*.jsonl`), frames with
  `isApiErrorMessage: true`: 21 × `rate_limit` (all the individual-spend-limit
  text with a reset clause), 9 × `server_error`, 1 × `invalid_request`,
  1 × `authentication_failed`. Zero `billing_error`.
- No surviving transcript or debug-log capture contains the wire `err.data` of
  an org-spend-cap error. Its `errorKind = "rate_limit"` comes from the CLI
  source (item 1), not from a capture.

## The `billing_error` mapping

`billing_error` is reachable, but not for this symptom. The CLI emits it at one
site only: an API error whose message contains `credit balance is too low`
(Console/API-key prepaid credits). Subscription spend caps never produce it.

Thus the current hint (`message_writer.lua:1493`) is wrong for the one case
that reaches it. It says "Organisation spend limit reached … run /usage-credits".
The correct action for low credit balance is to add funds in the Console. The
display-only dispatch (no reauth, no respawn, no auto-continue) is correct for
it.

## Fix direction

1. Map `rate_limit` → `usage_limit` in `error_kind_class`. The mapped branch
   (`:1621-1633`) then returns `reset_epoch = nil`. Thus the mapped branch must
   also scrape the reset clause from the text when present, or leave the
   epoch to the dispatch site.
2. At the dispatch site, take the reset epoch from `self._budget.resetsAt`.
   Normalise milliseconds the same way as `_budget_status`
   (`session_manager.lua:2670`). Use the text-scraped `reset_epoch` as the
   fallback. Keep the 3-value return of `format_error_lines`.
3. Call `offer_auto_continue` only when one of the two sources gives an epoch.
   With no epoch, show a hint and set no gate.
4. Correct the `billing_error` hint text to the low-credit-balance case.

## Open decisions

1. **Transient 429 vs limit rejection.** `rate_limit` also covers a plain 429
   (`Request rejected (429) · …`, `apiErrorIsTransient`). Mapping all of
   `rate_limit` to `usage_limit` makes a capacity 429 respawn the subprocess
   and set a gate. Decide if the class needs a second signal (a rejected
   `_budget.status`, or the message prefix `You've hit your` /
   `You've reached your`, which the bridge itself uses in
   `isSyntheticUsageLimitMessage`).
2. **Is `_budget` current at error time?** The bridge forwards
   `rate_limit_event` as a `usage_update` only when `lastAssistantTotalUsage`
   is not `null` (`acp-agent.js:4919-4930`). That value is reset at turn start
   (`:2475`). A turn rejected on its first request can therefore leave
   `_budget` at its pre-turn value. Capture a live rejection (event order and
   `status`) before `_budget.resetsAt` becomes the primary source.
3. **What to do with no epoch.** The org-spend-cap text has no reset clause.
   If `_budget` also has no usable `resetsAt`, decide between hint-only (no
   gate, no respawn) and respawn without auto-continue.
