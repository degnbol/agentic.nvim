# Plan: auto-retry transient server errors

Implemented. Two things differ from the plan below, both recorded at their
sections: the synthetic prompt got its own method rather than a flag through
`_handle_input_submit_inner`, and a retried failure is not fully invisible —
the CLI's `API Error: …` sentence arrives as prose before the JSON-RPC error.

## Problem

A mid-stream API failure ends the turn with a JSON-RPC error on
`session/prompt`, which `session_manager.lua:1865` renders as an `### Error`
block:

```
### Error

Internal error: API Error: Connection closed mid-response. The response above may be incomplete.
```

The partial response is already in the buffer and the ACP session is still
alive, so the only recovery is a fresh `continue` prompt — which the user
currently types by hand, every time. Automate that.

### Provenance

The bridge builds the error at `acp-agent.js:2558`: an SDK `result` message with
`subtype: "success"`, `is_error: true` →
`failActive(RequestError.internalError(errorKindData(lastAssistantError), message.result))`.
`lastAssistantError` is the `error` field of the last top-level assistant frame
(`acp-agent.js:2875-2883`, gated on `parent_tool_use_id === null`, reset per turn
at `:1228`), and `RequestError.internalError` prefixes the message with
`Internal error: ` (`@agentclientprotocol/sdk/dist/jsonrpc.js:1021`).

**`errorKind` is `server_error`.** Verified from the CLI's own transcripts
(`~/.claude/projects/**/*.jsonl`), where the synthetic assistant frame preceding
the result carries `"error": "server_error", "isApiErrorMessage": true,
"model": "<synthetic>"`. That frame is exactly the ordering `errorKindData`
needs (it returns `undefined` for a falsy kind, `acp-agent.js:4814-4816`), and
`server_error` is in the `SDKAssistantMessageError` enum (`sdk.d.ts:2901`).
Every `server_error` observed in that history:

| n | message |
| --- | --- |
| 9 | `API Error: Connection closed mid-response. The response above may be incomplete.` |
| 2 | `API Error: Unable to connect to API (ConnectionRefused)` |
| 2 | `API Error: 529 Overloaded.` |
| 1 | `API Error: Response stalled mid-stream. The response above may be incomplete.` |
| 1 | `API Error: Unable to connect to API (ENOTFOUND)` |

This resolves risk 2 in
[`bug-error-classification-structured-errorkind.md`](bug-error-classification-structured-errorkind.md)
("`server_error` left unmapped") — though see the retryability decision below
for why it stays unmapped in `error_kind_class` regardless.

Current display path: `error_kind_class` (`message_writer.lua:442`) has no
`server_error` entry, so `format_error_lines` finds no mapped kind, no embedded
JSON and no `resets …` clause, and exits via the raw-message fallback
(`:575`) — which is why the `Internal error: ` prefix survives
(`strip_error_prefix` only runs on the mapped-kind path).

### Why a new prompt is the only mechanism

- **No turn-level resume exists in ACP.** The client→agent surface (schema at
  `@agentclientprotocol/sdk/dist/schema/index.js`) has session lifecycle
  methods, prompt, cancel, mode/config setters, NES, document notifications and
  MCP passthrough — nothing that continues a closed turn. `session/resume`
  re-attaches to a *session*: `resumeSession` is `getOrCreateSession` with no
  replay (`acp-agent.js:775-781`) against `loadSession`'s `replaySessionHistory`
  (`:782`). Ours is alive; the *turn* is dead. Only `session/prompt` makes an
  agent generate.
- **Not redundant with the CLI's own retries.** `SDKAPIRetryMessage`
  (`subtype: "api_retry"`, fields `attempt`/`max_retries`/`retry_delay_ms`/
  `error_status`/`error`) retries the *HTTP request*. A mid-stream truncation
  cannot be replayed there without duplicating delivered tokens — which is what
  "The response above may be incomplete" reports. Our retry is a *new turn*, a
  different layer.
- **The subprocess survives.** `failActive` (`acp-agent.js:1501-1520`): "Reject
  the active turn … without tearing down the consumer: the stream continues to
  idle and later turns proceed." No respawn needed for this class.

## Constraints

- **v1 has no delay.** Retry immediately. Only add a wait if immediate retries
  prove to fail systematically, and then as v2.
- **Nothing the *plugin* writes fires until we give up.** No error block, no
  prompt heading, no bell, no unread badge, no `on_prompt_submit`, and
  `on_response_complete` only for the final outcome. `finalize_turn`
  (`message_writer.lua:661`) still runs per suppressed turn: one blank line
  (invisible), and it clears `_last_wrote_tool_call`, so if the stream died
  right after a tool call the retry's prose loses the `\n###\n\n` section close
  (`message_writer.lua:930`) that stops treesitter-context pinning the tool's
  filename. Both accepted.

  The *provider* is not silent, though. The CLI's synthetic error frame
  (`"error": "server_error"`, `model: "<synthetic>"`) carries its `API Error: …`
  text as a normal content block, and the bridge forwards it: `streamedBlocks`
  holds the truncated message's prose, the synthetic text is not a continuation
  of it, so the diff at `acp-agent.js:2938-2999` keeps the whole block and emits
  it as an `agent_message_chunk`. It lands glued onto the end of the prose with
  no separator — verified in persisted sessions, e.g. `"…separate repo from the
  commit.API Error: Connection closed mid-response."`. So the seam a suppressed
  error block would have explained is still marked, one layer down. Not worth
  filtering: doing so needs the text matching this design rejects everywhere
  else, and the sentence is the only in-buffer account of the stall.
- **`❯` and the `## ` heading come from `write_user_prompt`**
  (`message_writer.lua:380`, sign extmark at `:410-420`, owns the `---`
  separator). Any prompt through `_handle_input_submit` gets them, so the retry
  needs a path that skips it.
- **One dispatch per Stop.** On the retry path the `_drain_queue()` call at
  `session_manager.lua:1927` becomes conditional — the retry turn's own Stop
  drains the queue (same reasoning as `session_recovery.lua:454-456`). Every
  other path still needs it. Mid-turn queued regions therefore defer up to 3
  turns.
- **No delay means no timer**, so the `_retry_timer` gates at
  `session_manager.lua:1607` and `:1659` need no changes.

## Existing infrastructure to reuse

| Primitive | Location | Role |
| --- | --- | --- |
| Error dispatch site | `session_manager.lua:1865-1884` | Where the class is branched on; `_retry_attempt = 0` resets at `:1883`/`:1886` |
| `_notify_attention` | `session_manager.lua:124`, called `:1906` | Bell + unread badge; suppressed by not calling it |
| `_handle_input_submit_inner` | `session_manager.lua:1617` | Submit funnel; context assembly `:1670-1818`, `write_user_prompt` `:1820`, `add_message` `:1829`, `status_indicator:start` `:1831` |
| `send_prompt` callback | `session_manager.lua:1855-1928` | Turn tail: `finalize_turn` `:1893`, hooks `:1908`, `_drain_queue` `:1927` |
| `session_recovery.lua` | whole module | Home for recovery flows; `sm`-first convention, `@diagnostic disable: invisible` |
| `offer_auto_continue` guards | `session_recovery.lua:434-444` | `_destroyed` + `session_id` checks to mirror |
| `write_error_action` | `message_writer.lua:645` | Appends an `ERROR_BODY` line after an error block; give-up message uses it (`session_recovery.lua:370-375`) |
| `auto_continue_on_usage_limit` | `config_default.lua:82` | Sibling config flag to model the new one on |

## Approach decisions

### Retryability is a predicate, not an error class

The obvious move — add `server_error` to `error_kind_class`
(`message_writer.lua:442`) — is wrong. `format_error_lines` returns from its
embedded-JSON branch at `:541` with `error_hints[kind_class or error_type]`
(`:534`), so a mapped `server_error` outranks the JSON's own `overloaded_error`:
a 529 would lose its "The API is overloaded. Try again in a moment." hint, and
`message_writer.test.lua:2401-2414` (which uses `server_error` as its example of
an *unmapped* kind) would have to be rewritten.

Retryability is a recovery-policy question, not a display question. Keep
`error_kind_class` untouched and add a predicate in `session_recovery.lua`
reading `err.data.errorKind == "server_error"` directly. Consequences: no
reclassification, no lost hint, no test rewrite, and **no change to
`write_error_message` at all** — the dispatch site checks the predicate before
calling it, and the give-up path calls it exactly as today.

Cost: `err.data.errorKind` is then read in two places for two purposes. That is
the right split — display classification and retry policy are independent axes —
but worth a comment at each site.

No text heuristics, per the errorKind-first principle in
`bug-error-classification-structured-errorkind.md`. A bridge that omits
`err.data` silently never retries; see open questions.

### 529 Overloaded is retried too, uselessly, and that is accepted

`server_error` covers mid-stream truncation, 529 overload, and
connection-refused/ENOTFOUND alike. Nothing structural separates them: the
CLI-generated 529 text is prose (`API Error: 529 Overloaded. This is a
server-side issue, usually temporary…`) with no JSON body, while the fixture at
`message_writer.test.lua:2159` shows JSON-bearing 529s exist too — so "has
embedded JSON" is not a discriminator, and splitting them would take text
matching.

So a 529 or an offline machine burns the budget in ~3 fast failures and then
degrades to today's error block. Bounded, no loop, no worse than current
behaviour — just unhelpful for those subsets. Revisit as v2 if it bites.

### Retry budget on `SessionManager`, logic in `session_recovery.lua`

New private field `_transient_attempt` (`@field` at `session_manager.lua:104`,
init at `:210`). Separate from `_retry_attempt`, which is usage-limit specific
and consumed by `cancel_retry_timer(sm, reset_attempts)`.

**Increment before dispatch**, not after — the test mocks invoke the
`send_prompt` callback synchronously (`session_manager.test.lua:1404` fixture),
so a post-dispatch increment recurses forever.

Reset sites, all five: turn success (`:1886`), give-up, and the three teardown
paths where `_retry_attempt` is reset via `cancel_retry_timer`
(`session_manager.lua:2148`, `:2287`, `:2323`). Note `:1883` — the `else` for
non-auth non-usage-limit errors — no longer covers it once `transient_error` has
its own branch, so a `transient → auth` chain would otherwise leave a stale
budget.

`Recovery.retry_after_transient_error(sm)` carries its own `_destroyed` and
`session_id` guards: the `send_prompt` callback at `session_manager.lua:1856`
has none.

Budget 3, behind `Config.auto_retry_on_transient_error` (boolean, default true)
next to `auto_continue_on_usage_limit`. Named for the internal concept, not for
claude-agent-acp's `server_error` enum value — gemini-acp and codex-acp will
never emit it.

### Synthetic submit: nothing user-authored is recorded

**Built differently from the plan.** The intent below is unchanged, but a flag
through `_handle_input_submit_inner` would have put a suppression conditional
inside a 210-line function whose name promises it handles *input submission*.
Instead the turn tail — per-turn state reset, `send_prompt`, error dispatch,
finalization, notifications, queue drain — moved to
`SessionManager:_dispatch_turn(prompt)`, shared verbatim by both callers, and
`_send_synthetic_prompt(text)` is the second entry point. Nothing is skipped by
a branch; the user-intent steps simply are not on that path, so a future
addition to `_handle_input_submit_inner` cannot silently leak into a retry.

What the synthetic path therefore does not run:

- `write_user_prompt` (`:1820`) — the heading, `❯` sign and `---` separator.
- `chat_history:add_message` (`:1829`) — a client-side artefact; omitting it
  makes a Path B restore read the response as one continuous turn.
- **The whole context-assembly block** (`:1670-1818`). `code_selection`,
  `file_list` and `diagnostics_list` are populated by user commands
  (`session_manager.lua:2396`, `:2408`, `:2417`) with no `is_generating` gate,
  so the user can attach `@file`s while the dying turn streams. Those belong to
  the user's *next* prompt, not to a retry — skipping leaves them pending, which
  is both minimal and correct. Also skips the `chat_history.title == ""`
  retitle branch (`:1677`) and `clear_unread_badge`/`close_if_all_completed`
  (`:1618-1619`).

Prompt content is the bare string. `status_indicator:start("thinking")`
(`:1831`) still runs — the turn genuinely is resuming.

Prompt text: hardcode `"continue"`, mirroring `session_recovery.lua:452`. There
is no configurable alternative — `config_default.lua:240` is `keymaps.prompts`,
a keymap-lhs→text map (`["<localLeader>c"] = "Continue"`), and `057618d`
generalised that keybinding, not the retry prompt.

### Give-up

On the 4th failure, `write_error_message` as today, then `write_error_action`
with a line naming the retry count — matching how `offer_auto_continue` reports
giving up (`session_recovery.lua:370-375`). Without it the user sees one error
after a several-second stall with no account of what happened.

## As built

- `Recovery.should_retry_transient(sm, err, turn_session_id)` — answers "does a
  retry go out?", not just "is this error retryable?". The caller suppresses the
  error block, bell, hook and drain on this one answer, so every reason a retry
  could not be dispatched is decided here or the failure would go unreported:
  config flag, `errorKind == "server_error"`, `_destroyed`, budget, session
  identity, agent readiness. `MAX_TRANSIENT_RETRIES = 3` is local to
  `session_recovery.lua`.
  - **Session identity** matters because a pending `session/prompt` callback
    outlives `cancel_session`, which drops the subscriber but not
    `ACPClient.callbacks`. A failure arriving after `/new`, a restore or a
    provider switch would otherwise inject an unprompted turn into the
    *replacement* session. Same hazard class as `_session_epoch`.
  - **Agent readiness** because `_dispatch_turn` calls `send_prompt` directly;
    only `_handle_input_submit` has the ready gate that stashes to
    `_pending_input`, and `offer_auto_continue` inherits it by going through
    that funnel.
- `Recovery.retry_after_transient_error(sm)` — increments the budget (before
  dispatch, or a synchronous callback never terminates) and sends. Guards live
  in the predicate, so the counter and its bound stay in one module.
- `SessionManager:_dispatch_turn` / `_send_synthetic_prompt` — see the synthetic
  submit section.
- `_transient_attempt` on `SessionManager`, reset on turn success, on any error
  that is not being retried, and at the three teardown sites next to
  `Recovery.cancel_retry_timer(self)`. The reset sits at the call sites rather
  than inside `cancel_retry_timer`, whose name is about the usage-limit timer.
- Give-up line: `Auto-retry gave up (%d attempts).` via `write_error_action`,
  keyed on `_transient_attempt > 0` rather than on the error still being
  transient — so a `transient → auth` chain also accounts for its silent turns
  and cannot leave a stale budget.
- `message_writer.lua` untouched, and its error tests unchanged — the payoff of
  keeping retryability off the classification axis.
- Seven cases in `session_manager.test.lua` (nested in `send_prompt error
  dispatch`, reusing its fixture): recovery leaves no trace, give-up reports 3,
  no retry without the kind, when disabled, into a replaced session, or with a
  non-ready agent, and a chain ending in another class. The fixture grew a
  `sink` collecting error writes, action lines, prompts, synthetic prompts,
  prompt headings, history entries and drain calls, so "leaves no trace" is
  asserted against the writes themselves rather than proxied by the bell.

## Residual open questions

1. **Tool re-execution on retry** is accepted: there is no signal to gate on and
   a new prompt is the only way forward. Same exposure as the manual workflow,
   but silent once automated. Recorded in `doc/agentic.txt` under the config
   flag.
2. **A once-only prompt prefix consumed by the failed turn is not resent.**
   `_history_to_send` (Path B) and `_is_first_message` (the `environment_info`
   block) are cleared when the prompt is *built*, so the bare `continue` carries
   neither. Harmless for the observed failures — mid-stream truncation means the
   provider ingested the prompt and its session holds the prefix — but a
   `ConnectionRefused` on the first prompt after a Path B restore would silently
   drop the replayed history. Not guarded: nothing distinguishes "prompt never
   arrived" from "generation died", so re-stashing would duplicate the prefix in
   the common case.

Resolved:

- **`err.data.errorKind` is on the wire**, settled statically rather than by
  waiting for a live failure. `errorKindData(kind)` returns `{ errorKind }`
  (`acp-agent.js:4814`), `RequestError.internalError(data, msg)` stores it as
  `this.data` and `toErrorResponse()` serialises it verbatim
  (`@agentclientprotocol/sdk/dist/jsonrpc.js:1020`, `:1053`). `server_error` is
  in `SDKAssistantMessageError` (`sdk.d.ts:2901`) and appears 15× across
  `~/.claude/projects/**/*.jsonl` on frames carrying `isApiErrorMessage: true`
  — against 27 `rate_limit` and 2 `authentication_failed`, and no `overloaded`,
  which is why 529s arrive as `server_error`.

- **Mid-fence resumption.** If the stream died inside a ` ``` ` block,
  `finalize_turn`'s `_reflow_chunks(bufnr, true)` closes the fence
  (`message_writer.lua:793-798`, `:855`) and the model may not re-open one — the
  failure mode in
  [`bug-unclosed-prose-fence-runaway-fold.md`](bug-unclosed-prose-fence-runaway-fold.md).
  Not a regression: this happens identically when the user types `continue` by
  hand, and the provider's own `API Error: …` line still marks the seam.
- **The retry's prompt echo does not render a phantom `## continue`.**
  `session_manager.lua:565` renders `user_message_chunk` as a full user prompt,
  and the bridge runs with `replay-user-messages` (`acp-agent.js:4478`) — but a
  replayed echo matching a queued turn is dropped from the feed
  (`acp-agent.js:2775-2866`), and `failActive` (`:1503`) removes the dead turn
  from `turnQueue` so it cannot mis-match. Recorded because the synthetic path
  depends on bridge behaviour, not plugin behaviour.

## Adjacent findings — separate work

- **Orphaned tool-call blocks keep a non-terminal status footer.** A call cut
  mid-flight is never resolved: `finalize_turn` touches no block statuses, and
  blocks are dropped only per-id when their range extmark collapses
  (`message_writer.lua:1531`). `_cancel_session` (`session_manager.lua:2145-2155`,
  `:2284-2294`) doesn't clear them either, so this already happens today on
  cancel — it is a pre-existing bug, not one this feature introduces, and
  suppressing the error block only makes it more confusing. Deliberately **not**
  fixed here, because the obvious fix is unsafe: marking such a block `failed`
  with a `failure_reason` re-runs `prepare_block_lines` on the invariant "a
  failed file-mutating tool never applied its change, so the file is unchanged
  and reproduces the same diff" (`message_writer.lua:1543-1547`) — which is
  false for a mid-stream truncation, since the subprocess survives and the edit
  may have landed. Re-extraction would produce an empty or inverted diff. Needs
  its own note covering turn scoping (`tool_call_blocks` spans the whole
  session), whether to attach a reason at all, and the diff-re-extraction
  guard.
- **The bell over-fires generally.** `_notify_attention` (`:124`) rings whenever
  the chat is unfocused at turn end. Suppressing it on the retry path is scoped
  to this plan; the broader "only ring when input is actually needed" question
  is separate.
- **`respawn_after_usage_limit` may rest on a stale claim.**
  `session_manager.lua:1871-1877` and `session_recovery.lua:283-290` assert the
  bridge's prompt generator does not close on `RequestError.internalError`, and
  that later prompts return `end_turn` with zero usage. Bridge 0.66.0 documents
  the opposite at that exact site (`failActive`, `acp-agent.js:1503`) — and that
  is the mechanism a manual `continue` relies on. If the claim no longer holds,
  the respawn is paying a subprocess kill plus a Path B history re-prefix for
  nothing. This plan deliberately does not respawn.
- **`error_kind_class`'s `billing_error` entry may be dead.** The org spend
  limit arrives as errorKind `rate_limit` in all 27 occurrences in the
  transcript history, with no `billing_error` anywhere. Relevant to Phase B
  decision 1 in
  [`bug-error-classification-structured-errorkind.md`](bug-error-classification-structured-errorkind.md).
- **`api_retry` is dropped by the bridge** (`acp-agent.js:2202`,
  `// Todo: process via status api`). Forwarding it would let the plugin show
  retry progress instead of a silent stall. Upstream feature request; nothing
  recoverable client-side.
