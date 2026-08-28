# PLAN: surface hook activity in the chat buffer

Status: **phases 1 and 2 shipped; 3 to 5 remain.** The tail read, decoder,
per-session reader and the injected-context fold row are in the code, which is
the reference for them — see `read_appended`, `claude_hook_records.lua`,
`hook_record_reader.lua`, `MessageWriter:write_hook_block`, and the drains in
`SessionManager:{_finalize_turn, _on_tool_call_update}`. What remains is
failures and unrecognised output (phase 3), the optional PostToolUse drain (4),
and persistence (5). The record taxonomy and evidence below still govern those.

Evidence is first-hand: bridge/SDK source and plugin source at the pinned
versions, plus counts over this project's own transcript history. **Counts drift**
as sessions accumulate — quoted for shape, not as fixtures. Snapshot:
`claude-agent-acp` 0.66.0, `@anthropic-ai/claude-agent-sdk` 0.3.220, CLI 2.1.220.

Split out of this plan: showing *why* a tool call was permitted →
`notes/feature-why-permitted.md`. It shares a data source with this work but is a
separate UI concern.

## Goal

A hook that injects context, or that times out, is invisible in AgenticChat. Only
*blocking* hooks show, and only incidentally — a block becomes the tool result.

Make hook activity visible and attributable, without inventing a second source of
truth for the conversation itself.

## Why the ACP feed cannot carry this

| SDK system message | bridge handling | visible today |
| --- | --- | --- |
| `permission_denied` | `tool_call_update` `status:"failed"` (`acp-agent.js:2051`) | yes — as the tool result |
| `informational` | `agent_message_chunk` (`acp-agent.js:2107`) | yes — indistinguishable from model prose |
| `hook_started` / `hook_progress` / `hook_response` | bare `break` (`acp-agent.js:2129-2131`) | **no** |

`hook_response` is the payload we want (`sdk.d.ts:3916`). Two independent reasons
it never arrives:

1. `Options.includeHookEvents` defaults `false` (`sdk.d.ts:1619-1626`) and the
   bridge never sets it. It *is* settable — `_meta.claudeCode.options` is spread
   in at `acp-agent.js:4433` and `includeHookEvents` is not among the
   ACP-controlled overrides that follow (`:4446-4452`).
2. Enabling it changes nothing: the bridge drops the events regardless, and that
   switch's `default` arm is `unreachable()`. The SDK emits SessionStart/Setup
   hook events regardless of the flag; those are dropped too.

`additionalContext` is never a message at all — it is merged into the model's
context inside the CLI (`sdk.d.ts:6791`: *"non-error feedback delivered to the
model"*).

**Do not plan a fix inside `MessageWriter` or the adapters** for the dropped
events — the bytes never leave the bridge. Record the gap under CLAUDE.md §
"Upstream issues" so the local channel below reads as a stopgap.

Related: `notes/agentic-hook-blocked-rendering.md` owns the blocking case; its
"non-zero exits are invisible" caveat is the *Failures* category below.

### Hook feedback that arrives as model prose

A blocking `UserPromptSubmit` or `Stop` hook reaches the client as a real
`agent_message_chunk`, so it renders as if the model said it. The command-notice
work left this site as prose and deferred it here.

It is convertible, because the impersonating text is bridge-generated rather than
model-authored. ACP's `agent_message_chunk` has no severity field, so the bridge
folds the level into the text at `acp-agent.js:2107`, emitting `**Warning:** `,
`**Notice:** ` or `**Suggestion:** ` prefixes (level `info` is left plain as
transcript-only noise). A chunk beginning with one of those at a message boundary
is a hook notice, and can route to `write_notice` instead of the prose path.

This is a heuristic on generated text, not a protocol guarantee — the prefix set
is version-coupled to the bridge, and level `info` is indistinguishable from prose
by construction. Independent of the transcript reader; it needs only unit 1.

## The transcript is the channel

The CLI writes purpose-built records to
`~/.claude/projects/<slug>/<session-id>.jsonl`. **All hook records are nested
under `attachment`** — no top-level `"type":"hook_*"` envelope (2108/2108 nested,
0 top-level):

```json
{"type":"attachment","attachment":{
   "type":"hook_additional_context",
   "content":["Dotfiles conventions: when looking for any program's config…"],
   "hookName":"UserPromptSubmit","hookEvent":"UserPromptSubmit",
   "toolUseID":"hook-8ab624f2-…"},
 "uuid":"…","parentUuid":"…","timestamp":"…","sessionId":"5bcf246d-…"}

{"type":"attachment","attachment":{
   "type":"hook_success","hookName":"PreToolUse:Bash","hookEvent":"PreToolUse",
   "toolUseID":"toolu_01G2wfPp3cY3ADJNXx922NU9",
   "command":"~/.config/claude/hooks/shell-guard.sh",
   "content":"","stdout":"{\"hookSpecificOutput\":{…}}","stderr":"",
   "exitCode":0,"durationMs":142},
 "uuid":"…","parentUuid":"…", …}
```

`hook_success` carries exactly those ten keys — no `outcome`.

### Getting the path

`transcript_path` is on every `BaseHookInput` (`sdk.d.ts:166`), and the plugin's
own PreToolUse hook already receives the whole hook input: `permission_hook.sh`
base64s stdin into `permission_hook.lua`, which decodes it at
`permission_hook.lua:57` and currently reads only `tool_name` / `tool_input` /
`session_id`. One extra field read.

**Read the field only — add no work to that script.** It is the one that hangs
(all three `hook_cancelled` records are `hooks/permission_hook.sh` at 600 s), and
its verdict computation is wrapped in a `pcall` returning abstain on error, so any
failure inside it silently changes a permission decision. See
`notes/feature-why-permitted.md` § "Hard constraint".

Prefer this over deriving the path from the cwd slug. Three limits, which shape
the design rather than being worked around:

- **claude-only.** Registered through `_meta.claudeCode.options`
  (`acp_client.lua:20-36`). Other providers never supply a path; the feature
  no-ops.
- **Gated on the hook matcher** `Bash|Write|Edit` (`acp_client.lua:25`). A session
  that only Reads/Greps/Fetches never learns the path.
- **Arrives late** — unknown until the first matching tool call, possibly several
  turns in. Hence the catch-up rule in "Reader design".

**Guard against a subagent path.** Subagent transcripts
(`<session-id>/subagents/agent-*.jsonl`) carry the *same* `sessionId` as the
parent, so a hook firing inside a subagent hands back a subagent path. No hook
records exist in any subagent file here, so it may never fire, but
`basename(path) == session_id .. ".jsonl"` is one line and removes the risk.

### Ownership, ordering, and attribution

```
L28  assistant  tool_use                        parent=L27
L30  hook_success             PreToolUse:Bash    parent=L28   ← branch off the call
L31  hook_success             PreToolUse:Bash    parent=L30
L32  hook_additional_context  PreToolUse:Bash    parent=L31   ← points at its producer
L33  user       tool_result                      parent=L28   ← also off the call
```

Hook records form a **sibling branch** off the invoking `tool_use`; the
`tool_result` parents straight back to the `tool_use`, bypassing them. So an
injection is provably *not part of the tool result* — it is a separate input the
model received. That is the basis for rendering it as its own region.

- **File order gives sequence; `parentUuid` gives the precise link.** Most
  `hook_additional_context` records point at the `hook_success` that produced
  them — that is how a body is attributed to a *script*.
- **Do not attribute on `toolUseID`** — over a hundred context records share a `toolUseID` with
  2–3 `hook_success` records. **Do not attribute on `hookName`** either:
  `hook_success` carries a matcher suffix the context record lacks
  (`SessionStart:startup` vs `SessionStart`).
- **`hookName` alone does not identify a body.** ~20 tool calls carry two context
  records with identical `hookName` from different scripts, so the `command` join
  is load-bearing for the foldtext, not optional enrichment.
- **`toolUseID:match("^toolu_")` distinguishes tool-owned from turn-boundary
  records.** All `toolu_` records resolve to a `tool_use` in the same file; zero
  orphans. The other forms are not a single synthetic prefix: `UserPromptSubmit`
  uses `hook-<uuid>`, `SessionStart` uses `SessionStart…` *or* a bare uuid, `Stop`
  uses bare uuids. Both kinds render as blocks (see "Rendering"), so this filter
  is for *heading* and *placement*, not for discarding anything.

**Ordering is not uniform:**

```
PreToolUse  before tool_result: 1835/1835
PostToolUse after  tool_result:   56/56
```

The bridge corroborates (`acp-agent.js:5948-5950`): *"a PostToolUse hook can fire
after that"*.

## Record taxonomy

Exactly four attachment types carry a `hookEvent`:

| type | count | meaning |
| --- | --- | --- |
| `hook_success` | 1670 | a hook ran to completion |
| `hook_additional_context` | ~358 | context delivered to the model |
| `hook_non_blocking_error` | ~84 | non-zero exit, ignored |
| `hook_cancelled` | ~3 | timed out — keys are exactly `{type, hookName, hookEvent, toolUseID, command, durationMs, timedOut, timeoutMs}`, **no `stdout`/`exitCode`/`content`** |

Sub-classify `hook_success` on the **parsed** `stdout.hookSpecificOutput` keys —
never on substring presence, which false-positives when a rewritten Bash command
contains the word. Parsed, the classes sum exactly:

| `hookSpecificOutput` | count | agent saw it |
| --- | --- | --- |
| `permissionDecision` | 1309 | no — out of scope, see `notes/feature-why-permitted.md` |
| `additionalContext` | 259 | yes — **duplicates `hook_additional_context`** |
| `updatedInput` | 49 | no — see `notes/PLAN-updated-input-display.md` |
| `additionalContext` + `updatedInput` | 9 | partly — **the classes are not disjoint** |
| unparseable stdout | 24 | no |
| empty stdout | 20 | no |
| | **1670** | |

Read bodies only from `hook_additional_context`; `hook_success` is the roster of
what ran. Otherwise the 259+9 render twice.

Do not claim a per-call record bound: attachments per `toolUseID` are
`{1: 1474, 2: 96, 3: 89, 4: 7, 5: 12}`.

### What gets rendered

Three categories, referred to by name throughout the rest of this plan.

#### Injected context

`hook_additional_context`, ~358 records. The content the model received. Every one
renders, whether tool-owned or turn-boundary:

| origin | count |
| --- | --- |
| tool-owned (`PreToolUse:*`, `PostToolUse:*`) | ~217 |
| turn-boundary (`SessionStart`, `UserPromptSubmit`, `Stop`) | ~141 |

#### Unrecognised output

`hook_success` with no known `hookSpecificOutput` key (44 = 24 unparseable + 20
empty stdout). Intended as "a guard ran and passed quietly", but no such record
exists — there are no tool-owned *silent* passes:

```
20  Stop             completion-review.sh   → no owning call, content empty
13  PreToolUse:Edit  nvim-cmd-guard.sh      → toolu_-owned, content NON-empty
11  PreToolUse:Write nvim-cmd-guard.sh      → toolu_-owned, content NON-empty
```

Every tool-owned record carries `content`. At the time of writing it read
`m='`:help'` — a shell-assignment leak from that script rather than deliberate
output, since fixed.

**Surface it anyway.** The category is "output we do not recognise", and both
things it can be are worth seeing: a hook bug shows up early instead of silently
producing nothing, and an unfamiliar schema is not quietly discarded. That is why
this is a second body channel rather than a relabelling of the roster — it renders
`hook_success.content`, unlike injected context which renders
`hook_additional_context`.

#### Failures

Content-gated. `hook_cancelled` always;
`hook_non_blocking_error` only when it carries real stderr. All ~84 current
non-blocking errors have `stdout == ""`, `exitCode == 1` and the SDK's placeholder
stderr:

```
"Failed with non-blocking status code: No stderr output"
```

so the gate is implementable only as *stderr ≠ that literal* — **version-coupled
to the CLI**; revisit on bump. Ungated it would raise 84 false alarms about
working hooks (`path-skill-guard.sh` ×82, `bell.sh` ×2, all exiting 1 as a
"nothing to say" return). The gate keeps the timeouts, all three of which are
`hooks/permission_hook.sh` at 600 s — *our own* hook hanging.

## Rendering

**Each record is one closed fold row, appended to the chat buffer — no heading.**
A hook injection is a separate input the model received between tool uses, even
when the preceding tool call is what triggered it, so it is its own region rather
than part of the tool call's output. `SessionStart`, `UserPromptSubmit` and `Stop`
records are not special-cased.

Shipped as `MessageWriter:_write_collapsed_region`, which thought runs and hook
blocks now share: a `markdown-fold` fence closed explicitly at render, a
`sign_text` glyph on the fence's first body row, `set_dim_range` over the body,
and `wrap_prose` so the foldtext's line count matches what `zo` shows. The
heading-avoidance rationale (`queries/agentic/context.scm` pins the breadcrumb
on a *titled* heading over a fenced body) is in `write_hook_block`'s docstring.

Glyph constraints come from `PLAN-gutter-identity.md` § "Glyph vocabulary".
`󰛢` U+F06E2 `nf-md-hook` satisfies all of them and is now spent.

`content` is a list whose single element is **plain text** (358/358) — do not
attempt a second JSON parse one level in. Bodies run 25–1844 chars (1–25 lines).

Appending a region rather than mutating a tool-call block avoids three constraints
a fields-on-the-block design would have to change: the frozen-diff early return
for Edit/Write (the `already_has_diff` branch in
`MessageWriter:update_tool_call_block`), the single-valued `fold_anchor`/`fold_open`
return contract in `prepare_block_lines`, and `vim.tbl_deep_extend` replacing
list-valued fields in the `ToolCallBase` merge.

**Placement of late records.** PreToolUse records (1835/1835, the overwhelming
majority) are on disk before the terminal `tool_call_update`, so draining there
appends immediately after the tool-call block — the correct position. PostToolUse
records (56, of which ~28 are injected context) land after the tool result; if the drain
waits until turn end, intervening prose will already have been written and the
block appends after it. Options: accept the slight misordering, or adopt trigger 3
below to drain promptly. Not blocking — it affects ~28 records.

**Nothing to do for the blocking case.** A block arrives as a `tool_result` with
`is_error`, already lifted into `ToolCallBase.failure_reason`.

## Triggers

Two real signals plus one that needs an adapter change:

1. **Terminal `tool_call_update`** — covers every PreToolUse record, and appends
   in the right place. Shipped, at the end of `SessionManager:_on_tool_call_update`
   and skipping subagent calls.
2. **Turn end.** Shipped as `SessionManager:_finalize_turn`, the chokepoint every
   `message_writer:finalize_turn()` call site now routes through. It drains
   *after* the writer, not before: the turn-usage footer is stamped on the
   buffer's last row, which a region drained first would move out from under it.
   (The other reason its docstring gives — a region written first ends the prose
   run and leaves the summary unbracketed — no longer holds now that every run
   ending brackets, including the one a hook region would end.)
3. **The bridge's PostToolUse-callback `tool_call_update`**
   (`acp-agent.js:5966-5979`) — **currently dropped before the plugin sees it.**
   `ClaudeAgentACPAdapter:__handle_tool_call_update` returns early when `not update.status
   and (not rawInput or empty)`, and that update has neither. Optional: it only
   buys prompt placement for the ~28 PostToolUse injected-context records. If adopted the change
   must be **drain-only** — admitting it into `__build_tool_call_update`
   would set `body` from `extract_content_body`, mutating
   `tracker.body` through the `---` divider path (the body-merge divider path in `update_tool_call_block`)
   even though `already_has_diff` prevents any re-render, and that mutated body is
   what gets persisted (the `ChatHistory.ToolCall` projection in `SessionManager:_on_tool_call_update`).

   Scope if adopted: fires for every tool *except* TodoWrite and `Task*` (skipped
   at `acp-agent.js:5930-5944`), never for a tool that did not run; registration
   is gated on `registerHooks` (`:5946`), false only inside `replaySessionHistory`
   (`:3622`), so live turns always register.

Byte offsets make drains non-duplicating, and reads are synchronous so concurrent
drains cannot interleave. Turn cancellation (Ctrl-C), turn errors and
`respawn_after_usage_limit` all still reach a `finalize_turn`, so trigger 2 covers
them.

## Reader design

Minimal I/O: given a path and a byte offset, return newly appended lines and the
new offset.

**Catch-up on first path discovery, not `fs_stat` at load.** The path is unknown
until the first matching hook fires — by which time the file size also swallows the
current turn's records. Instead: record a wall-clock marker when the session is
created *or* loaded; on first path discovery, read the file once and keep records
with `timestamp >= marker`; then set the offset to the file size. All hook records
carry a UTC `Z` ISO-8601 `timestamp`, so the comparison is a plain string compare.
This collapses the new-vs-resume special case into one rule and prevents a resumed
session re-rendering its entire history (up to ~1.8 MB).

One record has no timestamp to compare: a `verbatim` one, whose line did not
parse and so has no envelope to read it from. Those are placed by the read they
arrive on instead — the catch-up read is the only one that can return bytes
older than the reader, so anything after it is new by construction
(`HookRecordReader:_is_current`). Without that rule a resumed session dumps
every historical unparseable line at once.

- A separate process appends: `new_offset` points **just past the last complete
  line**. That *is* the carry-the-remainder mechanism — no separate remainder
  state.
- **`size < offset` → reset the offset.** `seek("set", offset)` past EOF returns
  nothing, permanently. Covers compaction, rotation, and replacement under the
  same name.
- Filter to `type == "attachment"` with a `hookEvent`, then dispatch by group.
- Subagent transcripts out of scope (and see the basename guard above).

Error handling, against the "never silently swallow" rule: a record that does not
parse is *rendered verbatim* — visible, not swallowed. A missing or unreadable
transcript when a path *was* supplied surfaces once via `Logger.notify`;
`debug_to_file` alone is off by default and would hide it.

## Structure

Shipped as three pieces, each documented at its own definition:
`FileSystem.read_appended`, `claude_hook_records.lua` (pure decode, no IO or
state), and `hook_record_reader.lua` (one per session, built in
`SessionManager:new` and replaced in `_cancel_session` alongside `ChatHistory`
so a stale path and offset cannot outlive their session). Rendering goes through
`MessageWriter:write_hook_block`, no heading.

Why a sibling file rather than an addition to `claude_utils.lua`: that module is
"constants and helpers for the Claude ACP adapter" and jsonl record decoding is
a different contract. Why a reader object rather than two fields on the
2700-line `SessionManager`: `.claude/rules/multi-tabpage.md`, no module-level
per-tabpage state.

## Persistence

A standalone hook block wants a new `ChatHistory.Message` variant — the alias has
no hook case today (`chat_history.lua:23-27`). That is the clean route, and notably
*cheaper* than the alternative: a new `ToolCallBase` field would be silently
dropped by both hand-picked field projections
(the `ChatHistory.ToolCall` projections in `SessionManager:_on_tool_call_update` and `session_restore.lua`), the known class in
`notes/bug-chat-history-drops-tool-call-enrichment.md`.

Restore is phased last. Until it lands, say so in the writer's docstring so the
next reader does not file the absence as a bug.

## Phasing

1. **Shipped.** `read_appended` + the reader object (path, marker, offset,
   `drain()`) + the decoder.
2. **Shipped.** Injected context as fold rows on triggers 1 and 2 — the bulk of
   the value (~358 records).
3. Failures and unrecognised output. `SessionManager:_drain_hook_records`
   already receives both groups and discards them; the work is a second glyph
   (`failure` needs one from `PLAN-gutter-identity.md` § "Glyph vocabulary") and
   deciding what an empty-bodied `unrecognised` record renders as, which
   `_write_collapsed_region` currently drops.
4. Optional: trigger 3 (adapter change, drain-only) for prompt placement of the
   ~28 PostToolUse records.
5. Persistence — new `ChatHistory.Message` variant.

Tests are **co-located `<module>.test.lua`** per `.claude/rules/tests.md`.
`make validate` is the gate.

## The fold row

**The script basename in the foldtext, and nothing else.** Where the row lands
already says what the event was — beside a tool call for
`PreToolUse`/`PostToolUse`, at the turn boundary for
`SessionStart`/`UserPromptSubmit`/`Stop` — so naming the event is redundant with
position. The glyph says "hook". The only thing position and glyph do not carry is
which script ran:

```
󰛢 ··· shell-guard.sh · 8 lines ···
󰛢 ··· json-validate.sh · 3 lines ···
󰛢 ··· 12 lines ···                     ← no name available
```

**How the name reaches the foldtext, revised from the sign dispatch this plan
first proposed.** An extmark carries no payload beyond its two sign cells, so
the sign can say *that* a row is a hook but never *which script*. The writer
instead appends the basename to the fence's info string
(```` ```markdown-fold shell-guard.sh ````) and `folds.lua`'s `fence_source`
reads it back off the row above the fold. Both queries key on the
`(info_string (language))` node — the first word alone, verified against the
parser — so neither folding nor markdown injection notices the extra word, and
`is_fence_delimiter` still conceals the row to zero height. The sign dispatch
remains for the thought run's character count, which needs no payload.

`hookName` is not a fallback. It is lossy enough to give adjacent rows identical
summaries over different bodies: `PreToolUse:Bash` covers five scripts
(`shell-guard` 56, `git-repo-guard` 38, `bash-pitfall-guard` 24,
`nvim-headless-remind` 22, `jq-guard`), `PreToolUse:Edit` five more.

**No name means no name shown.** The `parentUuid` join lands for 253 of 339
records; all 86 misses are `UserPromptSubmit`, whose records never point at a
`hook_success`, so no script name exists. Those fall back to the plain line count —
which is the unmodified foldtext, so it costs nothing.

Foldtext is virtual text, not buffer content, so markdown never parses it. That
removes the emphasis hazard a raw-text heading would have carried for basenames
containing two underscores (`my_hook_name.sh` → `_hook_`).
